{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecursiveDo #-}
module DeBruijn where

import Numeric
import Numeric.Lens
import Data.Function
import Data.Word
import Data.Int
import Data.Bits hiding (bit)
import qualified Data.Bits as Bits
import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import Data.Typeable
--import qualified Data.FingerTree as F
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Sequence as S
import qualified Data.Set as Set
import qualified Data.Map as M
import qualified Data.IntSet as IS
import qualified Data.IntMap.Strict as IM
import qualified Data.Vector as V
import qualified Data.Vector.Storable as US
import qualified Data.Vector.Storable.Mutable as U
import Control.Applicative
import Control.Arrow
import Control.Monad.State
import Control.Monad.Except
import Control.Monad.Reader
import Control.Lens as Lens
import Control.Concurrent
import Control.Exception (evaluate)
import Control.DeepSeq
import System.Directory
import System.FilePath (takeFileName)
import "Glob" System.FilePath.Glob
--import Data.IORef
import Sound.ALUT (play, stop, sourceGain, pitch, ($=))

import System.IO.Unsafe
import Unsafe.Coerce
import Debug.Trace

import Hdis86 hiding (wordSize)
import Hdis86.Pure

import Helper
import Edsl hiding (Flags, trace_, ips, sps, segAddr_, (>>), when, return, Info, addressOf)
import qualified Edsl (Part_(Flags))
import MachineState

data List a = Con a (List a) | Nil

data Var :: List * -> * -> * where
    VarZ :: Var (Con a e) a
    VarS :: Var e a -> Var (Con b e) a

data EExp :: List * -> * -> * where
    Var' :: Var e a -> EExp e a

    C' :: a -> EExp e a
    Let' :: EExp e a -> EExp (Con a e) b -> EExp e b
    Iterate' :: EExp e Int -> EExp (Con a e) a -> EExp e a -> EExp e a

    Tuple' :: EExp e a -> EExp e b -> EExp e (a, b)
    Fst' :: EExp e (a, b) -> EExp e a
    Snd' :: EExp e (a, b) -> EExp e b
    If' :: EExp e Bool -> EExp e a -> EExp e a -> EExp e a

    Get' :: Part_ (EExp e) a -> EExp e a

    Eq' :: Eq a => EExp e a -> EExp e a -> EExp e Bool
    Sub', Add', Mul' :: Num a => EExp e a -> EExp e a -> EExp e a
    And', Or', Xor' :: Bits a => EExp e a -> EExp e a -> EExp e a
    Not', ShiftL', ShiftR', RotateL', RotateR' :: Bits a => EExp e a -> EExp e a
    Bit' :: Bits a => Int -> EExp e a -> EExp e Bool
    SetBit' :: Bits a => Int -> EExp e Bool -> EExp e a -> EExp e a
    HighBit' :: FiniteBits a => EExp e a -> EExp e Bool
    SetHighBit' :: FiniteBits a => EExp e Bool -> EExp e a -> EExp e a
    EvenParity' :: EExp e Word8 -> EExp e Bool

    Signed' :: AsSigned a => EExp e a -> EExp e (Signed a)
    Extend' :: Extend a => EExp e a -> EExp e (X2 a)
    Convert' :: (Integral a, Num b) => EExp e a -> EExp e b
    SegAddr' :: EExp e Word16 -> EExp e Word16 -> EExp e Int

data EExpM :: List * -> * -> * where
    LetM' :: EExp e a -> EExpM (Con a e) b -> EExpM e b
    QuotRem' :: Integral a => EExp e a -> EExp e a -> EExpM e b -> EExpM (Con (a,a) e) b -> EExpM e b
    Input' :: EExp e Word16 -> EExpM (Con Word16 e) () -> EExpM e ()

    Seq' :: EExpM e b -> EExpM e c -> EExpM e c
    IfM' :: EExp e Bool -> EExpM e a -> EExpM e a -> EExpM e a
    Replicate' :: EExp e Int -> EExpM e () -> EExpM e ()
    Cyc2' :: EExp e Bool -> EExp e Bool -> EExpM e () -> EExpM e ()

    Nop' :: EExpM e ()
    Trace' :: String -> EExpM e ()
    Set' :: Part_ (EExp e) a -> EExp e a -> EExpM e ()
    Jump'' :: EExp e Word16 -> EExp e Word16 -> EExpM e ()
    Output' :: EExp e Word16 -> EExp e Word16 -> EExpM e ()

data Layout :: List * -> List * -> * where
  EmptyLayout :: Layout env Nil
  PushLayout  :: {-Typeable t 
              => -}Layout env env' -> Var env t -> Layout env (Con t env')

size :: Layout env env' -> Int
size EmptyLayout        = 0
size (PushLayout lyt _) = size lyt + 1

inc :: Layout env env' -> Layout (Con t env) env'
inc EmptyLayout         = EmptyLayout
inc (PushLayout lyt ix) = PushLayout (inc lyt) (VarS ix)

prjIx :: Int -> Layout env env' -> Var env t
prjIx _ EmptyLayout       = error "Convert.prjIx: internal error"
prjIx 0 (PushLayout _ ix) = unsafeCoerce ix --fromJust (gcast ix)
                              -- can't go wrong unless the library is wrong!
prjIx n (PushLayout l _)  = prjIx (n - 1) l

convExp :: Exp a -> EExp Nil a
convExp = convExp_ EmptyLayout

convExp_ :: forall a e . Layout e e -> Exp a -> EExp e a
convExp_ lyt = g where
      h :: forall a e . Layout e e -> Exp a -> EExp e a
      h = convExp_

      g :: forall a . Exp a -> EExp e a
      g = \case
        Var sz -> Var' (prjIx (size lyt - sz - 1) lyt)

        C a -> C' a
        Let e f -> Let' (g e) $ h (inc lyt `PushLayout` VarZ) $ f $ Var (size lyt)
        Iterate n f e -> Iterate' (g n) (h (inc lyt `PushLayout` VarZ) $ f $ Var (size lyt)) (g e)

        Tuple a b -> Tuple' (g a) (g b)
        Fst a -> Fst' $ g a
        Snd a -> Snd' $ g a
        If a b c -> If' (g a) (g b) (g c)

        Get p -> Get' (convPart lyt p)

        Eq a b -> Eq' (g a) (g b)
        Sub a b -> Sub' (g a) (g b)
        Add a b -> Add' (g a) (g b)
        Mul a b -> Mul' (g a) (g b)
        And a b -> And' (g a) (g b)
        Or a b -> Or' (g a) (g b)
        Xor a b -> Xor' (g a) (g b)
        SetBit i a b -> SetBit' i (g a) (g b)
        SetHighBit a b -> SetHighBit' (g a) (g b)
        SegAddr a b -> SegAddr' (g a) (g b)
        Not a -> Not' (g a)
        ShiftL a -> ShiftL' (g a)
        ShiftR a -> ShiftR' (g a)
        RotateL a -> RotateL' (g a)
        RotateR a -> RotateR' (g a)
        Bit i a -> Bit' i (g a)
        HighBit a -> HighBit' (g a)
        EvenParity a -> EvenParity' (g a)
        Signed a -> Signed' (g a)
        Extend a -> Extend' (g a)
        Convert a -> Convert' (g a)

convExpM :: ExpM a -> EExpM Nil a
convExpM = f EmptyLayout where
    h :: forall a e . Layout e e -> Exp a -> EExp e a
    h = convExp_

    f :: forall e a . Layout e e -> ExpM a -> EExpM e a
    f lyt = k where
      q :: forall a . Exp a -> EExp e a
      q = h lyt

      k :: forall a . ExpM a -> EExpM e a
      k = \case
        LetM e g -> LetM' (q e) $ f (inc lyt `PushLayout` VarZ) $ g $ Var (size lyt)
        QuotRem a b x g -> QuotRem' (q a) (q b) (k x) $ f (inc lyt `PushLayout` VarZ) $ g $ unTup $ Var (size lyt)
        Input e g -> Input' (q e) $ f (inc lyt `PushLayout` VarZ) $ g $ Var (size lyt)

        Seq a b -> Seq' (k a) (k b)
        IfM a b c -> IfM' (q a) (k b) (k c)
        Replicate n a -> Replicate' (q n) (k a)
        Cyc2 e f a -> Cyc2' (q e) (q f) (k a)
        Nop -> Nop'
        Trace s -> Trace' s
        Jump' cs ip -> Jump'' (q cs) (q ip) --Seq' (Set' (convPart lyt Cs) (q cs)) (Set' (convPart lyt IP) (q ip))
        Set Cs _ -> error "convExpM: set cs"
--        Set IP _ -> error "convExpM: set ip"
        Set p e -> Set' (convPart lyt p) (q e)
        Output a b -> Output' (q a) (q b)

convPart :: Layout e e -> Part_ Exp a -> Part_ (EExp e) a
convPart lyt = mapPart (convExp_ lyt)

