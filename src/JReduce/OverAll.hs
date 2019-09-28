-- |
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ApplicativeDo #-}
module JReduce.OverAll where

-- lens
import Control.Lens

-- jvmhs
import Jvmhs

-- containers
import qualified Data.IntSet as IS
import qualified Data.Set as S

-- unordered-containers
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS

-- text
import qualified Data.Text as Text

-- mtl
import Control.Monad.Reader

-- base
import Data.Maybe
import qualified Data.List as L
import Data.Monoid
import Data.Foldable

-- filepath
import System.FilePath

-- cassava
import qualified Data.Csv as C

-- bytestring
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString.Builder as BS

-- reduce-util
import Control.Reduce.Reduction
import Control.Reduce.Problem
import Control.Reduce.Graph
import qualified Control.Reduce.Util.Logger as L

-- jvmhs
import Jvmhs.Data.Named
import Jvmhs.Data.Code
import Jvmhs.Data.Signature
import Jvmhs.Transform.Stub

-- jvm-binary
import qualified Language.JVM.ByteCode as B
import qualified Language.JVM.Constant as B

-- jreduce
import JReduce.Target
import JReduce.Config


data Item
  = IContent Content
  | ICode ((Class, AbsMethodName), Code)
  | ITarget Target
  | ISuperClass (Class, ClassType)
  | IImplements (Class, ClassType)
  | IField (Class, Field)
  | IMethod (Class, Method)
  | IInnerClass (Class, InnerClass)

instance C.ToField ([Int], Item) where
  toField (i, x) =
    BL.toStrict . BS.toLazyByteString
    $ "|" <> BS.stringUtf8 (L.intercalate "|". map show . reverse $ i)
    <> " " <> case x of
      IContent (Jar _) -> "jar"
      IContent (ClassFile c) ->
        BS.stringUtf8 (Text.unpack $ c^.className.fullyQualifiedName)
      IContent (MetaData _) -> "metadata"
      ICode ((_, m), _) ->
        BS.stringUtf8 (Text.unpack $ absMethodNameToText m )
        <> "!code"
      ITarget _ -> "base"
      ISuperClass (c, _) ->
        BS.stringUtf8 (Text.unpack $ c^.className.fullyQualifiedName)
        <> "!superclass"
      IInnerClass (_, ic) ->
        BS.stringUtf8 (Text.unpack $ ic^.innerClass.fullyQualifiedName)
        <> "!isinner"
      IImplements (_, ic) ->
        BS.stringUtf8 (Text.unpack $ ic^.classTypeName.fullyQualifiedName) <> "!implemented"
      IField (c, field) ->
        BS.stringUtf8
          . Text.unpack
          . absFieldNameToText
          $ mkAbsFieldName (c^.className) (field^.name)

      IMethod (c, method) ->
        BS.stringUtf8
          . Text.unpack
          . absMethodNameToText
          $ mkAbsMethodName (c^.className) (method^.name)

makePrisms ''Item

data Fact
  = ClassExist ClassName
  | CodeIsUntuched AbsMethodName
  | IsSuperClass ClassName
  | FieldExist AbsFieldName
  | IsInnerClass ClassName ClassName
  | MethodExist AbsMethodName
  | IsImplemented ClassName
  deriving (Eq, Ord)

instance C.ToField Fact where
  toField = \case
    ClassExist _ -> "class"
    CodeIsUntuched _ -> "unstubbed"
    IsSuperClass _ -> "issuper"
    FieldExist _ -> "field"
    IsInnerClass _ _ -> "isinnerclass"
    IsImplemented _ -> "isimplemented"
    MethodExist _ -> "method"

targetClasses :: Target -> [Class]
targetClasses = toListOf (folded.go)
  where
    go :: Getting (Endo [Class]) Content Class
    go = _ClassFile <> _Jar.folded.go


describeProblem ::
  MonadIOReader Config m
  => FilePath
  -> Problem a Target
  -> m (Problem a [IS.IntSet])
describeProblem wf p = do
  let targets = targetClasses $ _problemInitial p
  let scope = S.fromList . map (view className) $ targets

  hry <- L.phase "Calculating the hierachy" $ do
    r <- preloadClasses

    hry <- fmap (snd . fst) . flip runClassPoolT
      (HM.fromList [ (c^.className, c) | c <- targets])
      $ do
      L.phase "Loading classes in class path" .  void 
        $ loadClassesFromReader (ReaderOptions False r)
      getHierarchy

    L.debug $ "Hierachy calculated, processed #"
      <> L.display (HM.size $ hry ^. hryStubs)
      <> " classes."

    return hry

  let
    p2 = liftProblem (review _ITarget) (fromJust . preview _ITarget) p

  liftIO
    . BL.writeFile (wf </> "graph.csv")
    . writeCSV
    . fst . reductionGraph (keyFun scope hry) itemR
    $ _problemInitial p2

  return (toGraphReductionDeep (keyFun scope hry) itemR p2)

classConstructors :: Fold Class AbsMethodName
classConstructors =
  classAbsMethodNames . filtered (elemOf methodId "<init>")

classInitializers :: Fold Class AbsMethodName
classInitializers =
  classAbsMethodNames . filtered (elemOf methodId "<clinit>")




keyFun :: S.Set ClassName -> Hierarchy -> Item -> (Maybe Fact, [Fact])
keyFun scope hry = \case
  IContent (ClassFile cls) ->
    ( Just (ClassExist $ cls ^.className)
    , concat
      [ (( classBootstrapMethods . traverse . classNames
         <> classTypeParameters . traverse . classNames
          <> classEnclosingMethod . _Just . (_1 <> _2 . _Just . classNames)
        ) . to (makeClassExist cls) )
        `toListOf` cls
      , if cls ^. classAccessFlags . contains CEnum
        then cls ^.. classAbsFieldNames . to FieldExist
        else []
      , [ MethodExist mname
        | m <- cls ^. classMethods
        , let mname = (mkAbsMethodName (cls^.className) (m^.name))
        , m' <- declarations hry mname
        , not (scope ^. contains (m' ^.inClassName))
        ]
        -- If the class is an innerclass it needs to reference that
      , [ IsInnerClass (cls ^.className) (cls ^.className) ]
        -- If you can not remove the super class, don't remove the
        -- annotation
      , [ IsSuperClass (cls ^. className) ]
      , [ IsSuperClass cn
        | cn <- cls ^.. classSuper.folded.classTypeName
        , not (scope ^. contains cn)
        ]
        -- If you cannot remove the interface class, don't remove the
        -- annotation
      , [ IsImplemented (cls ^. className)
        | cls ^. classAccessFlags . contains CInterface ]
      , [ IsImplemented cn
        | cn <- cls ^.. classInterfaces.folded.classTypeName
        , not (scope ^. contains cn)
        ]

      -- If a field is synthetic it can exist for multiple
      -- reasons:
      --   - It is used to preload values to embeded
      --     methods.
      , [ FieldExist (mkAbsFieldName (cls^.className) (f^.name))
        | f <- cls ^. classFields
        , f ^. fieldAccessFlags . contains FSynthetic
        ]
      ]
    )

  ISuperClass (cls, ct) ->
    ( Just (IsSuperClass $ ct ^.classTypeName)
    , concat
      [ map CodeIsUntuched (toListOf classConstructors cls)
      , ct ^..classNames.to (makeClassExist cls)
      ]
    )

  IField (cls, field) ->
    ( Just (FieldExist $ mkAbsFieldName (cls^.className) (field^.name) )
    , flip toListOf field . fold $
      [ classNames . to ClassExist
      , fieldAccessFlags . folding
        (\a ->
          if FFinal `S.member` a
          then
            CodeIsUntuched <$>
            if FStatic `S.member` a
            then toListOf classInitializers cls
            else toListOf classConstructors cls
          else []
        )
      ]
      --ClassExist cn : map CodeIsUntuched (toListOf classConstructors cls)
    )

  -- You can remove an implements statement if you can remove the class
  IImplements (cls, ct) ->
    ( Just (IsImplemented $ ct^.classTypeName)
    , [ makeClassExist cls cn' | cn' <- ct^..classNames]
    )

  IInnerClass (cls, ic) ->
    ( Just (IsInnerClass (cls^.className) $ ic ^. innerClass)
    , toListOf (classNames . to ClassExist) ic
    )

  IMethod (c, m) ->
    ( Just . MethodExist $ mname
    , concat
      [ map (makeClassExist c) $ toListOf methodClassNames m
      -- This rule is added to handle cases where the interface is generic.
      -- In this case an synthetic method with the correct types are created.
      , [ CodeIsUntuched mname
        | m^.methodAccessFlags.contains MSynthetic ]

      -- If a method is abstact find it's definitions.
      , [ MethodExist (mkAbsMethodName cn (m ^. name))
        | m ^. methodAccessFlags . contains MAbstract
        , cn <- HS.toList $ definitions hry mname
        , cn /= c ^. className
        ]
      ]
    )
    where
      mname = mkAbsMethodName (c^.className) (m ^. name)

      methodClassNames =
        methodDescriptor . classNames
        <> methodExceptions . traverse
        <> methodSignature . _Just . classNames

  ICode ((cls, m), code) ->
    ( Just (CodeIsUntuched m)
    , codeDependencies cls code
    )

  ITarget _ -> (Nothing, [])
  IContent _ -> (Nothing, [])


  where
    makeClassExist :: Class -> ClassName -> Fact
    makeClassExist cls thcls
      | has (fullyQualifiedName.to (Text.findIndex (=='$'))._Just) thcls
      = IsInnerClass (cls^.className) thcls
      | otherwise = ClassExist thcls

    codeDependencies :: Class -> Code -> [Fact]
    codeDependencies cls = toListOf
      $ ( ( codeExceptionTable.folded.classNames
            <> codeStackMap._Just.classNames
            <> codeByteCode.folded.classNames
          )
          . to (makeClassExist cls)
        )
      <> codeByteCode.folded.to B.opcode.folding processOpCode

    processOpCode :: B.ByteCodeOpr B.High -> [Fact]
    processOpCode = \case
      B.Get _ f -> [FieldExist f]
      B.Put _ f -> [FieldExist f]
      B.Invoke a -> case a of
        B.InvkSpecial (B.AbsVariableMethodId _ m') -> findMethod m'
        B.InvkVirtual m' -> findMethod m'
        B.InvkStatic  (B.AbsVariableMethodId _ m') -> findMethod m'
        B.InvkInterface _ (B.AbsInterfaceMethodId m') -> findMethod m'
        B.InvkDynamic (B.InvokeDynamic _ _) -> []
      _ -> []

      where
        findMethod m' =
          [ MethodExist m'' | m'' <- maybeToList $ declaration hry m']

itemR :: PartialReduction Item Item
itemR f' = \case
  ITarget t ->
    fmap ITarget <$> targetR f' t
  IContent c ->
    fmap IContent <$> contentR f' c
  IMethod (c, m) ->
    fmap (IMethod . (c,)) <$> (part $ methodR c) f' m
  a -> pure (Just a)
  where
    contentR :: PartialReduction Content Item
    contentR f = \case
      ClassFile c -> fmap ClassFile <$> (part classR) f c
      Jar c       -> fmap Jar <$> (deepDirForestR . reduceAs _IContent) f c
      a           -> pure $ Just a

    targetR :: PartialReduction Target Item
    targetR = deepDirTreeR . reduceAs _IContent

    classR :: Reduction Class Item
    classR f c = do
      (super :: Maybe ClassType) <- case c ^. classSuper of
        Just a
          | a ^. classTypeName == "java/lang/Object" ->
            pure $ Just  a
          | otherwise ->
           (payload c . reduceAs _ISuperClass) f a <&> \case
             Just a' -> Just a'
             Nothing -> Just (ClassType "java/lang/Object" [])
        Nothing ->
          pure $ Nothing

      fields <-
        (listR . payload c . reduceAs _IField) f (c ^. classFields)

      methods <-
        (listR . payload c . reduceAs _IMethod) f (c ^. classMethods)

      innerClasses <-
        (listR . payload c . reduceAs _IInnerClass) f (c ^. classInnerClasses)

      interfaces <-
        (listR . payload c . reduceAs _IImplements) f (c ^. classInterfaces)

      pure $ c
        & classSuper .~ super
        & classFields .~ fields
        & classMethods .~ methods
        & classInnerClasses .~ innerClasses
        & classInterfaces .~ interfaces

    methodR :: Class -> Reduction Method Item
    methodR cls f m =
      case m ^. methodCode of
        Just c -> f (ICode ((cls, mkAbsMethodName (cls ^.className) (m ^. name)), c)) <&> \case
          Just (ICode (_, c')) -> m & methodCode ?~ c'
          _ -> stub m
        _ -> pure m


 -- where
 --   processByteCode :: B.ByteCodeOpr B.High -> State [B.VerificationTypeInfo B.High] [Fact]
 --   processByteCode = \case
 --     B.Put _ a -> undefined

 --     B.Invoke a -> case a of
 --       B.InvkSpecial _ ->
 --         undefined

payload ::
  Functor f =>
  p
  -> ((p, a) -> f (Maybe (p, a)))
  -> a -> f (Maybe a)
payload p fn a =
  fmap snd <$> fn (p, a)
