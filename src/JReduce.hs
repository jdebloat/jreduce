{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE ViewPatterns        #-}

module JReduce where

-- lens
import           Control.Lens

-- deepseq
import           Control.DeepSeq

-- zip-archive
import           Codec.Archive.Zip

-- mtl
import           Control.Monad.Reader

-- filepath
import           System.FilePath

-- -- directory
-- import           System.Directory

-- cassava
import qualified Data.Csv                              as C

-- optparse-applicative
import           Options.Applicative                   as A

-- reduce
import           Data.Functor.Contravariant.PredicateM

-- bytestring
import qualified Data.ByteString.Lazy                  as BL

-- reduce-util
import           Control.Reduce.Util
import           Control.Reduce.Util.Logger            as L hiding (update,
                                                             view)
import           Control.Reduce.Util.OptParse
import           System.Directory.Tree

-- unordered-containers
import qualified Data.HashMap.Strict                   as HashMap
import qualified Data.HashSet                          as HashSet

-- containers
import qualified Data.IntSet                           as IS

-- unliftio
import           UnliftIO.Directory

-- text
import qualified Data.Text.Lazy.Builder as Builder

-- time
import Data.Time.Clock.System

-- base
import           Data.Foldable
import           Data.Functor
import           Data.Char
import qualified Data.List as L
import           Data.Maybe
import           System.Exit


-- jvhms
import           Jvmhs


data Validation
  = Reject
  | Shrink
  | NoValidation
  deriving (Show, Eq)

data Strategy
  = ByItem Validation
  | ByClosure
  deriving (Show, Eq)

strategyReader :: ReadM Strategy
strategyReader = maybeReader $ \s -> do
  let
    name = map toLower s
    check = guard . L.isPrefixOf name
  asum
    [ check "closure" $> ByClosure
    , check "reject-item" $> ByItem Reject
    , check "shrink-item" $> ByItem Shrink
    , check "item" $> ByItem NoValidation
    ]

data Config = Config
  { _cfgLogger           :: !Logger
  , _cfgCore             :: !(HashSet.HashSet ClassName)
  , _cfgClassPath        :: ![ FilePath ]
  , _cfgUseStdlib        :: !Bool
  , _cfgJreFolder        :: !(Maybe FilePath)
  , _cfgTarget           :: !FilePath
  , _cfgOutput           :: !(Maybe FilePath)
  , _cfgRecursive        :: !Bool
  , _cfgStrategy         :: !Strategy
  , _cfgReducerName      :: !ReducerName
  , _cfgPredicateOptions :: !PredicateOptions
  } deriving (Show)

makeClassy ''Config

instance HasLogger Config where
  loggerL = cfgLogger

configParser :: Parser (IO Config)
configParser = do

  _cfgTarget <-
    strArgument
    $ metavar "INPUT"
    <> help "the path to the jar or folder to reduce."

  _cfgLogger <- parseLogger

  ioCore <-
    fmap readClassNames . many . strOption
    $ short 'c'
    <> long "core"
    <> metavar "CORE"
    <> hidden
    <> help "the core classes to not reduce. Can add a file of classes with prepending @."

  _cfgClassPath <-
    fmap concat . many
    . fmap splitClassPath
    . strOption
    $ long "cp"
      <> hidden
      <> metavar "CLASSPATH"
      <> help ("the library classpath of things not reduced. "
               ++ "This is useful if the core files is not in the reduction, like when you are"
               ++ "reducing a library using a test-suite"
               )

  _cfgUseStdlib <-
    switch $ long "stdlib"
    <> hidden
    <> help "load the standard library? This is unnecessary for most reductions."

  _cfgJreFolder <-
    optional . strOption $ long "jre"
    <> hidden
    <> metavar "JRE"
    <> help "the location of the stdlib."


  _cfgOutput <-
    optional . strOption
    $ short 'o'
    <> long "output"
    <> hidden
    <> metavar "FILE"
    <> help "set the output path."

  _cfgRecursive <-
    switch $
    long "recursive"
    <> short 'r'
    <> hidden
    <> help "remove other files and reduce internal jars."

  _cfgStrategy <-
    option strategyReader
    $ short 'S'
    <> long "strategy"
    <> metavar "STRATEGY"
    <> hidden
    <> help ( "reduce by class instead of by closure (default: closure)." ++
              "Choose between closure, reject-item, and item." )
    <> value ByClosure

  _cfgReducerName <-
    parseReducerName

  ioPredicateOptions <-
    parsePredicateOptions "jreduce"

  pure $ do
    _cfgCore <- ioCore
    _cfgPredicateOptions <- ioPredicateOptions
    return $ Config {..}

  where
    readClassNames classnames' = do
      names <- fmap concat . forM classnames' $ \cn ->
        case cn of
          '@':filename -> lines <$> readFile filename
          _            -> return [cn]
      return . HashSet.fromList . map strCls $ names

main :: IO ()
main = do
  cfg <- join . execParser $
    A.info (configParser <**> helper)
    ( fullDesc
    <> header "jreduce"
    <> progDesc "A command line tool for reducing java programs."
    )

  runReaderT run cfg

run :: ReaderT Config IO ()
run = do
  workFolder <- view $ cfgPredicateOptions . to predOptWorkFolder
  (tclss, textra') <- unpackTarget (workFolder </> "unpacked")
  let clss = toClassList tclss

  textra <- view cfgRecursive >>= \case
    True -> L.phase "remove extra files" $ do
      let extras = toFileList textra'
      predOpt' <- view cfgPredicateOptions
      let predOpt = predOpt' { predOptWorkFolder = workFolder </> "extra-files" }
      toPredicateM predOpt (fromDirTree "classes" . (tclss <>)  . fromJust . fromFileList . unCount) (counted extras) >>= \case
        Just predicate -> do
          rname <- view cfgReducerName
          reduce rname Nothing predicate counted extras >>= \case
            Just reduction -> do
              return . fromJust . fromFileList . unCount $ reduction
            Nothing -> do
              failwith "The reduced result did not satisfy the predicate (flaky?)"
        Nothing ->
          failwith "Could not satisify the predicate."
    False -> return $ textra'

  classreader <- preloadClasses
  void . flip runCachedClassPoolT (defaultFromReader classreader) $ do
    setupPredicate (classesToFiles textra) clss >>= \case
      Just predicate -> do
        t' <- fromMaybe (fromClasses clss) <$> classReduction predicate clss
        liftRIO (runPredicateM predicate t') >>= \case
          True -> outputResults workFolder textra (ccContent t')
          False ->
            failwith "The reduced result did not satisfy the predicate (flaky?)"
      Nothing -> do
        failwith "Could not satisfy the predicate."
  where
    failwith ::
      (HasLogger env, MonadReader env m, MonadIO m)
      => Builder.Builder
      -> m a
    failwith msg = do
      L.err msg
      liftIO $ exitWith (ExitFailure 1)

    outputResults workFolder textra t' =
      view cfgOutput >>= \case
      Just output
        | isJar output -> liftIO $ do
            let tmpFolder = (workFolder </> output)
            writeTreeWith copySame $ tmpFolder :/ classesToFiles textra t'
            arc <- withCurrentDirectory tmpFolder $ do
              addFilesToArchive [OptRecursive] emptyArchive ["."]
            BL.writeFile output (fromArchive arc)
        | otherwise -> liftIO $ do
          writeTreeWith copySame $ output :/ classesToFiles textra t'
      Nothing ->
        L.warn "Did not output to output."

    copySame fp = \case
      SameAs fp' -> copyFile fp' fp
      Content bs -> BL.writeFile fp bs

    toClassList =
      catMaybes
      . map (\(a,b) -> (,b) <$> asClassName a)
      . toFileList

    classesToFiles textra clss =
      textra <> classesToFiles' clss

    classesToFiles' clss =
      fromJust . fromFileList . map (_1 %~ relativePathOfClass) $ clss

data ClassCounter a = ClassCounter
  { ccClosures :: Int
  , ccClasses  :: Int
  , ccContent  :: a
  } deriving (Functor)

fromClasses :: Foldable t => t a -> ClassCounter (t a)
fromClasses classData =
  ClassCounter 0 (length classData) classData

type ClassFiles = ClassCounter [(ClassName, FileContent)]

instance Metric (ClassCounter a) where
  order = Const ["scc", "classes"]
  fields ClassCounter {..} =
    [ "scc" C..= ccClosures
    , "classes" C..= ccClasses
    ]

setupPredicate ::
  (HasLogger env, HasConfig env, MonadReader env m, MonadClassPool m, MonadIO m)
  => ([(ClassName, FileContent)] -> DirTree FileContent)
  -> [(ClassName, FileContent)]
  -> m ( Maybe ( PredicateM (ReaderT env IO) ClassFiles ) )
setupPredicate classesToFiles classData = L.phase "Setup Predicate" $ do
  predOpt <- view cfgPredicateOptions
  liftRIO $
    toPredicateM
      predOpt
      (fromDirTree "classes" . classesToFiles . ccContent)
      $ fromClasses classData

classReduction ::
  forall m env a.
  (HasLogger env, HasConfig env, MonadReader env m, MonadClassPool m, MonadIO m)
  => PredicateM (ReaderT env IO) (ClassCounter [(ClassName, a)])
  -> [(ClassName, a)]
  -> m (Maybe (ClassCounter [(ClassName, a)]))
classReduction predicate targets = L.phase "Class Reduction" $ do
  (coreFp, flip shrink (map fst targets) -> grph) <- computeClassGraph
  L.debug $ "Possible reduction left:" <-> display (graphSize grph)

  rname <- view cfgReducerName

  view cfgStrategy >>= \case
    ByItem validate -> do
      predicate' <- case validate of
        NoValidation ->
          return predicate

        Reject -> do
          return . PredicateM $ \x ->
            if flip isClosedIn grph . map fst . ccContent $ x
            then runPredicateM predicate x
            else return False

        Shrink -> do
          return $
            (computeClassCounter.toValues.collapse grph.map fst.ccContent)
            `contramap` predicate

      liftRIO
        . reduce rname Nothing predicate' computeClassCounter $ targets
        where
          computeClassCounter =
            (\a -> ClassCounter (length a) (length a) a) . (coreFp ++)

    ByClosure ->  do
      closures' <- computeClosuresOfGraph grph

      liftRIO
        . reduce rname (Just $ IS.size . IS.unions)
            predicate (fromIntSet coreFp grph)
        $ closures'

  where
    fromIntSet coreFp graph scc = do
      let
        is = IS.unions scc
        cl = coreFp ++ (toValues $ labels (IS.toList is) graph)
      ClassCounter
        { ccClosures = length scc
        , ccClasses = length cl
        , ccContent = cl
        }

    computeClassGraph = L.phase "Compute Class Graph" $ do
      (coreCls, grph) <- forwardRemove <$> mkClassGraph <*> view cfgCore
      let coreFp = toValues coreCls
      L.debug
        $ "The core closure is" <-> display (length coreCls)
        <-> "classes," <-> display (length coreFp)
        <-> "in the target."
      return (coreFp, grph)

    computeClosuresOfGraph grph = L.phase "Compute closures of graph:" $ do
      let closures' = closures grph
      L.debug $ "Found" <-> display (length closures') <-> "SCCs."
      return $!! closures'

    graphSize = sumOf (grNodes . like (1 :: Int))

    values = HashMap.fromList targets

    toValues lst =
      let keepThese = HashSet.fromList $ lst
      in HashMap.toList (HashMap.intersection values (HashSet.toMap keepThese))


unpackTarget ::
  (MonadReader s m, MonadIO m, HasLogger s, HasConfig s)
  => FilePath -> m (DirTree FileContent, DirTree FileContent)
unpackTarget folder = do
  L.phase ("Unpacking target to" <-> display folder) $ do
    target <- view cfgTarget
    dx <- doesDirectoryExist target
    if dx
      then liftIO $ do
        _ :/ tree <- readTree target
        writeTreeWith (flip copyFileWithMetadata) (folder :/ tree)
      else liftIO $ do
        arch <- toArchive <$> BL.readFile target
        extractFilesFromArchive [OptDestination folder] arch

    _ :/ tree <- liftIO $ fmap SameAs <$> readTree folder

    return
      ( filterTreeOnFiles isClass tree
      , filterTreeOnFiles (not . isClass) tree
      )
  where
    isClass fn = takeExtension fn == ".class"

liftRIO ::
  (MonadReader env m, MonadIO m)
  => ReaderT env IO a -> m a
liftRIO m = do
  x <- ask
  liftIO $ runReaderT m x

preloadClasses :: ReaderT Config IO ClassPreloader
preloadClasses = L.phase "Preloading Classes" $ do
  cls <- createClassLoader
  (classreader, numclasses) <- liftIO $ do
    classreader <- preload cls
    numclasses <- length <$> classes classreader
    return (classreader, numclasses)
  L.debug $ "Found" <-> display numclasses <-> "classes."
  return classreader

-- | Create a class loader from the config
createClassLoader ::
  (HasConfig env, MonadReader env m, MonadIO m)
  => m ClassLoader
createClassLoader = do
  cfg <- ask
  let cp = cfg ^. cfgTarget : cfg ^. cfgClassPath
  if cfg ^. cfgUseStdlib
    then
      case cfg ^. cfgJreFolder of
        Nothing ->
          liftIO $ fromClassPath cp
        Just jre ->
          liftIO $ fromJreFolder cp jre
    else
      return $ ClassLoader [] [] cp
