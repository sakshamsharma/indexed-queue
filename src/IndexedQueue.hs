module IndexedQueue where

import           Control.Concurrent                       hiding
                                                           (getChanContents,
                                                           readChan, yield)
import           Control.Concurrent.Chan.Unagi.NoBlocking
import           Control.Exception
import           Control.Monad
import           Control.Monad.State.Lazy                 (lift, liftIO, liftM2,
                                                           when)
import           Control.Monad.Trans.State.Lazy
import           Data.Either.Combinators
import           Data.Hashable
import qualified Data.HashMap.Strict                      as H
import           Data.List
import           Data.Maybe
import           Pipes
import           System.CPUTime
import           System.IO.Unsafe

data IndexedQueue bareRep msgType msgIndex =
  IndexedQueue { channel       :: OutChan bareRep
               , bareToMsg     :: bareRep -> msgType
               , msgToIndex    :: msgType -> msgIndex
               , itemsInternal :: H.HashMap msgIndex [msgType]
               }

myProd :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType, MonadIO m) =>
          Integer -> a ->
          Producer msgType (StateT (IndexedQueue bareRep msgType msgIndex) m) a
myProd upto act = do
  now <- liftIO $ getCPUTime
  if (now > upto) then do
    ch <- lift $ gets channel
    mm <- liftIO $ tryReadChan ch >>= tryRead
    case mm of
      Nothing -> myProd upto act
      Just bmsg -> do
        conv <- lift $ gets bareToMsg
        yield (conv bmsg)
        myProd upto act
  else return act

myCons :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType, MonadIO m) =>
          (msgType -> m a) -> (a -> Bool) ->
          Consumer msgType (StateT (IndexedQueue bareRep msgType msgIndex) m) a
myCons action tocont = do
  start <- liftIO $ getCPUTime
  item <- await
  res <- lift $ lift $ action item
  if (tocont res) then myCons action tocont else return res

myEffc :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType, MonadIO m) =>
          msgIndex -> Integer -> (msgType -> m a) -> (a -> Bool) -> a ->
          Effect (StateT (IndexedQueue bareRep msgType msgIndex) m) a
myEffc idx timeout act tocont exit = do
  now <- liftIO $ getCPUTime
  myProd (now + timeout * 1000000) exit >-> myCons act tocont

recur :: (Eq msgIndex, Hashable msgIndex, Show msgIndex) => msgIndex ->
         OutChan bareRep -> (bareRep -> msgType) -> (msgType -> msgIndex) ->
         H.HashMap msgIndex [msgType] -> Integer -> Integer ->
         StateT (IndexedQueue bareRep msgType msgIndex) IO (Maybe msgType)
recur idx ch conv getIdx items start timeout = do
  now <- liftIO $ getCPUTime
  if now > start + timeout then return Nothing
  else do
    bmsgx <- liftIO $ tryReadChan ch >>= tryRead
    case bmsgx of
      Nothing -> recur idx ch conv getIdx items start timeout
      Just bmsg -> do
        let msg = conv bmsg
        let nidx = getIdx msg
        if (nidx == idx) then return $ Just msg
          else do
          modify $ \s -> s { itemsInternal = H.insertWith (++) nidx [msg] items }
          recur idx ch conv getIdx items start timeout

getItemTimeout :: (Eq msgIndex, Hashable msgIndex, Show msgIndex) => msgIndex -> Integer ->
                   StateT (IndexedQueue bareRep msgType msgIndex) IO (Maybe msgType)
getItemTimeout idx timeout = do
  cch <- gets channel
  conv <- gets bareToMsg
  getIdx <- gets msgToIndex
  items <- gets itemsInternal
  start <- liftIO $ getCPUTime
  recur idx cch conv getIdx items start (timeout * 1000000000)

addToQueue :: (Eq msgIndex, Hashable msgIndex) => msgType ->
              StateT (IndexedQueue bareRep msgType msgIndex) IO ()
addToQueue msg = do
  items <- gets itemsInternal
  getIdx <- gets msgToIndex
  modify $ \s -> s { itemsInternal = H.insertWith (++) (getIdx msg) [msg] items }
