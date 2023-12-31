{-@ LIQUID "--maxparams=4" @-}
{-@ LIQUID "--pruneunsorted" @-}

{-# OPTIONS_GHC -cpp -fglasgow-exts -fno-warn-orphans -fno-warn-incomplete-patterns -Wno-partial-type-signatures #-}

{-# LANGUAGE PartialTypeSignatures #-}

-- #prune

-- |
-- Module      : Data.ByteString.Lazy
-- Copyright   : (c) Don Stewart 2006
--               (c) Duncan Coutts 2006
-- License     : BSD-style
--
-- Maintainer  : dons@galois.com
-- Stability   : experimental
-- Portability : portable
-- 
-- A time and space-efficient implementation of lazy byte vectors
-- using lists of packed 'Word8' arrays, suitable for high performance
-- use, both in terms of large data quantities, or high speed
-- requirements. Byte vectors are encoded as lazy lists of strict 'Word8'
-- arrays of bytes. They provide a means to manipulate large byte vectors
-- without requiring the entire vector be resident in memory.
--
-- Some operations, such as concat, append, reverse and cons, have
-- better complexity than their "Data.ByteString" equivalents, due to
-- optimisations resulting from the list spine structure. And for other
-- operations lazy ByteStrings are usually within a few percent of
-- strict ones, but with better heap usage. For data larger than the
-- available memory, or if you have tight memory constraints, this
-- module will be the only option. The default chunk size is 64k, which
-- should be good in most circumstances. For people with large L2
-- caches, you may want to increase this to fit your cache.
--
-- This module is intended to be imported @qualified@, to avoid name
-- clashes with "Prelude" functions.  eg.
--
-- > import qualified Data.ByteString.Lazy as B
--
-- Original GHC implementation by Bryan O\'Sullivan.
-- Rewritten to use 'Data.Array.Unboxed.UArray' by Simon Marlow.
-- Rewritten to support slices and use 'Foreign.ForeignPtr.ForeignPtr'
-- by David Roundy.
-- Polished and extended by Don Stewart.
-- Lazy variant by Duncan Coutts and Don Stewart.
--

module Data.ByteString.LazyZip (
        -- * Zipping and unzipping ByteStrings
        zip,                    -- :: ByteString -> ByteString -> [(Word8,Word8)]
        zipWith,                -- :: (Word8 -> Word8 -> c) -> ByteString -> ByteString -> [c]

  ) where

import qualified Prelude
import Prelude hiding
    (reverse,head,tail,last,init,null,length,map,lines,foldl,foldr,unlines
    ,concat,any,take,drop,splitAt,takeWhile,dropWhile,span,break,elem,filter,maximum
    ,minimum,all,concatMap,foldl1,foldr1,scanl, scanl1, scanr, scanr1
    ,repeat, cycle, interact, iterate,readFile,writeFile,appendFile,replicate
    ,getContents,getLine,putStr,putStrLn ,zip,zipWith,unzip,notElem)

import qualified Data.List              as L  -- L for list/lazy
import qualified Data.ByteString        as S  -- S for strict (hmm...)
import qualified Data.ByteString.Internal as S
import qualified Data.ByteString.Unsafe as S
import Data.ByteString.Lazy.Internal
import qualified Data.ByteString.Fusion as F

import Data.Monoid              (Monoid(..))

import Data.Word                (Word8,Word64)
import Data.Int                 (Int64)
import System.IO                (Handle,stdin,stdout,openBinaryFile,IOMode(..)
                                ,hClose,hWaitForInput,hIsEOF)
import System.IO.Unsafe
#ifndef __NHC__
import Control.Exception        (bracket)
#else
import IO		        (bracket)
#endif

import Foreign.ForeignPtr       (withForeignPtr)
import Foreign.Ptr
import Foreign.Storable

--LIQUID
import Data.ByteString.Fusion (PairS(..), MaybeS(..))
import Data.Int
import Data.Word                (Word, Word8, Word16, Word32, Word64)
import Foreign.ForeignPtr       (ForeignPtr)

-- -----------------------------------------------------------------------------
--
-- Useful macros, until we have bang patterns
--

#define STRICT1(f) f a | a `seq` False = undefined
#define STRICT2(f) f a b | a `seq` b `seq` False = undefined
#define STRICT3(f) f a b c | a `seq` b `seq` c `seq` False = undefined
#define STRICT4(f) f a b c d | a `seq` b `seq` c `seq` d `seq` False = undefined
#define STRICT5(f) f a b c d e | a `seq` b `seq` c `seq` d `seq` e `seq` False = undefined

-- -----------------------------------------------------------------------------


{-@ predicate LZipLen V X Y  = (len V) = (if (lbLength X) <= (lbLength Y) then (lbLength X) else (lbLength Y)) @-}
{-@ zip :: x:ByteString -> y:LByteStringSZ x -> {v:[(Word8, Word8)] | (LZipLen v x y) } @-}
zip :: ByteString -> ByteString -> [(Word8,Word8)]
zip = zipWith (,)

-- | 'zipWith' generalises 'zip' by zipping with the function given as
-- the first argument, instead of a tupling function.  For example,
-- @'zipWith' (+)@ is applied to two ByteStrings to produce the list of
-- corresponding sums.
{-@ zipWith :: (Word8 -> Word8 -> a) -> x:ByteString -> y:LByteStringSZ x -> {v:[a] | (LZipLen v x y)} @-}
zipWith :: (Word8 -> Word8 -> a) -> ByteString -> ByteString -> [a]
zipWith _ Empty     _  = []
zipWith _ _      Empty = []
zipWith f (Chunk a as) (Chunk b bs) = go a as b bs (sz a as b bs) 0
  where
  --   go x xs y ys = f (S.unsafeHead x) (S.unsafeHead y)
  --                : to (S.unsafeTail x) xs (S.unsafeTail y) ys

  --   to x Empty         _ _             | S.null x       = []
  --   to _ _             y Empty         | S.null y       = []
  --   -- to x xs            y ys            | not (S.null x)
  --   --                                   && not (S.null y) = go x  xs y  ys
  --   to x xs            _ (Chunk y' ys) | not (S.null x) = go x  xs y' ys
  --   --LIQUID to _ (Chunk x' xs) y ys            | not (S.null y) = go x' xs y  ys
  --   --LIQUID to _ (Chunk x' xs) _ (Chunk y' ys)                  = go x' xs y' ys
  --   --LIQUID FIXME: these guards "should" be implied by the above checks
  --   to x (Chunk x' xs) y ys            | not (S.null y)
  --                                     && S.null x       = go x' xs y  ys
  --   to x (Chunk x' xs) y (Chunk y' ys) | S.null x
  --                                     && S.null y       = go x' xs y' ys

          {-@ go ::  x:ByteStringNE -> xs:ByteString
                 -> y:ByteStringNE -> ys:ByteString
                 -> ddd:{v:Nat64 | v = (bLength x) + (lbLength xs) + (bLength y) + (lbLength ys)}
                 -> zzz:{v:Nat64 | v = 0}
                 -> {v:[a] | (len v)
                           = (if (((bLength x) + (lbLength xs)) <= ((bLength y) + (lbLength ys)))
                             then ((bLength x) + (lbLength xs))
                             else ((bLength y) + (lbLength ys)))}
                  / [ddd, zzz] 
             @-}
          {- decrease go 6 7 @-}
          go ::  _ -> _ 
              -> _ -> _ 
              -> Int64
              -> Int64 
              -> [_] 
          go x xs y ys d (z :: Int64)
            = (f (S.unsafeHead x) (S.unsafeHead y))
            : (to (S.unsafeTail x) xs (S.unsafeTail y) ys (sz (S.unsafeTail x) xs (S.unsafeTail y) ys) 1)
          
          {-@ to :: x:_ -> xs:ByteString
                 -> y:_ -> ys:ByteString
                 -> dda:{v:Nat64 | v = (bLength x) + (lbLength xs) + (bLength y) + (lbLength ys)}
                 -> zza:{v:Nat64 | v = 1}
                 -> {v:[a] | (len v)
                           = (if (((bLength x) + (lbLength xs)) <= ((bLength y) + (lbLength ys)))
                             then ((bLength x) + (lbLength xs))
                             else ((bLength y) + (lbLength ys)))}
                 / [dda, zza]
             @-}
          
          {- decrease to 6 7 @-}
          
          to :: _ -- ByteString
             -> _ -- ByteString
             -> _ -- ByteString
             -> _ -- ByteString
             -> Int64 
             -> Int64
             -> [_] 
          
          to x Empty         _ _             d (_::Int64) | S.null x = []
          to _ _             y Empty         d _ | S.null y          = []
          to x xs            y ys            d _ | not (S.null x)
                                                  && not (S.null y) = go x  xs y  ys (sz x xs y ys) 0
          to x xs            _ (Chunk y' ys) d _ | not (S.null x) = go x  xs y' ys (sz x xs y' ys) 0
          --LIQUID to _ (Chunk x' xs) y ys            | not (S.null y) = go x' xs y  ys
          --LIQUID to _ (Chunk x' xs) _ (Chunk y' ys)                  = go x' xs y' ys
          --LIQUID FIXME: these guards "should" be implied by the above checks
          to x (Chunk x' xs) y ys            d _ | not (S.null y)
                                                  && S.null x       = go x' xs y  ys (sz x' xs y ys) 0
          to x (Chunk x' xs) y (Chunk y' ys) d _ | S.null x
                                                  && S.null y       = go x' xs y' ys (sz x' xs y' ys) 0
          
          
{-@ sz :: x:_ -> xs:_ 
       -> y:_ -> ys:_
       -> {v:Nat64 | v = ((bLength x) + (lbLength xs) + (bLength y) + (lbLength ys))}
  @-}
sz x xs y ys = fromIntegral (S.length x) + length xs
             + fromIntegral (S.length y) + length ys
          
{-@ qualif ByteStringNE(v:Data.ByteString.Internal.ByteString): (bLength v) > 0 @-}

{- qualif LBZip(v:List a,
                 x:S.ByteString,
                 xs:ByteString,
                 y:S.ByteString,
                 ys:ByteString):
    (len v) = (if (((bLength x) + (lbLength xs)) <= ((bLength y) + (lbLength ys)))
                   then ((bLength x) + (lbLength xs))
                   else ((bLength y) + (lbLength ys)))
  @-}

{-@ length :: b:ByteString -> {v:Int64 | v = (lbLength b)} @-}
length :: ByteString -> Int64
length = undefined
