{-# LANGUAGE MagicHash     #-}
{-# LANGUAGE UnboxedTuples #-}
{-# OPTIONS_GHC -Wno-missing-methods #-}

{-@ LIQUID "--no-totality"       @-}
{-@ LIQUID "--no-termination"    @-}
{-@ LIQUID "--no-pattern-inline" @-}

module ToyMVar where

import Prelude hiding (IO)
import Control.Applicative
import Data.Set 
data RealWorld
data MVar# s a 
data State# s 
data MVar a = MVar (MVar# RealWorld a)

data IO a = IO (State# RealWorld -> (State# RealWorld, a))
{-@ data IO a <p :: State# RealWorld -> Bool, q :: State# RealWorld-> a -> Bool>
      = IO (io :: (State# RealWorld)<p> -> ((State# RealWorld, a)<q>))
  @-}

{-@ measure inState :: MVar a -> State# RealWorld -> Bool @-}
{-@ measure stateMVars :: State# RealWorld -> Set (MVar a) @-}

{-@ newEmptyMVar  :: forall < p :: State# RealWorld -> Bool
                            , q :: State# RealWorld -> (MVar a) -> Bool>. 
                     IO <p, {\x y -> (inState y x)}> (MVar a) @-}
newEmptyMVar  :: IO (MVar a)
newEmptyMVar = IO $ \ s# ->
    case newMVar# s# of
         (s2#, svar#) -> (s2#, MVar svar#)

newMVar :: a -> IO (MVar a)
newMVar value =
    newEmptyMVar        >>= \ mvar ->
    putMVar mvar value  >>
    return mvar

putMVar  :: MVar a -> a -> IO ()
putMVar (MVar mvar#) x = IO $ \ s# ->
    case putMVar# mvar# x s# of
        s2# -> (s2#, ())


putMVar# :: MVar# s a -> a -> State# s -> State# s
putMVar# = let x = x in x

{-@ newMVar#  :: forall < p :: State# s -> Bool
                            , q :: State# s -> (MVar# s a) -> Bool>. 
                     (State# s)<p> -> 
                     ((State# s)<p>, (MVar# s a))<q> @-}

newMVar# :: State# s -> (State# s, MVar# s a)
newMVar# = let x = x in x

instance Monad IO where --  GHC-Base.lhs
  return = undefined
  _ >> _ = undefined

instance Applicative IO where
  pure  = undefined
  (<*>) = undefined

instance Functor IO where
  fmap = undefined
