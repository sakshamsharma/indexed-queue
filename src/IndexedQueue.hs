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

yoProd :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType, MonadIO m) =>
          Integer ->
          Producer msgType (StateT (IndexedQueue bareRep msgType msgIndex) m) ()
yoProd upto = do
  now <- liftIO $ getCPUTime
  unless (now > upto) $ do
    ch <- lift $ gets channel
    mm <- liftIO $ tryReadChan ch >>= tryRead
    case mm of
      Nothing -> yoProd upto
      Just bmsg -> do
        conv <- lift $ gets bareToMsg
        yield (conv bmsg)
        yoProd upto

myProd :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType, MonadIO m) =>
          Integer ->
          Producer msgType (StateT (IndexedQueue bareRep msgType msgIndex) m) (Maybe a)
myProd upto = do
  now <- liftIO $ getCPUTime
  if (now <= upto) then do
    ch <- lift $ gets channel
    mm <- liftIO $ tryReadChan ch >>= tryRead
    case mm of
      Nothing -> myProd upto
      Just bmsg -> do
        conv <- lift $ gets bareToMsg
        yield (conv bmsg)
        myProd upto
  else return Nothing

myCons :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType, MonadIO m) =>
          (msgType -> m (Maybe a)) ->
          Consumer msgType (StateT (IndexedQueue bareRep msgType msgIndex) m) (Maybe a)
myCons action = do
  item <- await
  res <- lift $ lift $ action item
  case res of
    Nothing -> myCons action
    Just x  -> return res

myEffc :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType, MonadIO m) =>
          msgIndex -> Integer -> (msgType -> m (Maybe a)) ->
          Effect (StateT (IndexedQueue bareRep msgType msgIndex) m) (Maybe a)
myEffc idx timeout act = do
  now <- liftIO $ getCPUTime
  myProd (now + timeout * 1000000000) >-> myCons act

accum :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType) =>
         Integer -> [msgType] ->
         StateT (IndexedQueue bareRep msgType msgIndex) IO [msgType]
accum upto acc = do
  now <- liftIO $ getCPUTime
  if (now > upto) then return acc
    else do
      ch <- gets channel
      mm <- liftIO $ tryReadChan ch >>= tryRead
      case mm of
        Nothing -> do
          liftIO $ threadDelay 400 -- 0.4ms
          accum upto acc
        Just bmsg -> do
          conv <- gets bareToMsg
          accum upto (conv bmsg : acc)

getItemsTimeout :: (Eq msgIndex, Hashable msgIndex, Show msgIndex, Show msgType) =>
                   msgIndex -> Integer ->
                   StateT (IndexedQueue bareRep msgType msgIndex) IO [msgType]
getItemsTimeout idx timeout = do
  now <- liftIO $ getCPUTime
  x <- accum (now + timeout * 1000000000) []
  return x

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
