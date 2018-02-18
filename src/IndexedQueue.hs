module IndexedQueue where

import           Control.Concurrent               hiding (getChanContents,
                                                   readChan)
import           Control.Concurrent.Chan.Unagi
import           Control.Exception
import           Control.Monad.State.Strict       (liftIO, liftM2)
import           Control.Monad.Trans.State.Strict
import           Data.Either.Combinators
import           Data.Hashable
import qualified Data.HashMap.Strict              as H
import           Data.List

data IndexedQueue bareRep msgType msgIndex =
  IndexedQueue { channel       :: OutChan bareRep
               , bareToMsg     :: bareRep -> msgType
               , msgToIndex    :: msgType -> msgIndex
               , itemsInternal :: H.HashMap msgIndex [msgType]
               }

-- Source: https://stackoverflow.com/questions/4964380
takeUntilTime :: Int -> [a] -> IO [a]
takeUntilTime limit list = do
    me <- myThreadId
    bracket (forkIO $ threadDelay limit >> throwTo me NonTermination) killThread
        . const $ tryTake list
  where
    (/:/) = liftM2 (:)
    tryTake list = handle (\NonTermination -> return []) $
        case list of
            []   -> return []
            x:xs -> evaluate x /:/ tryTake xs

storeMsgsForLater :: (Eq msgIndex, Hashable msgIndex) => OutChan bareRep -> [msgType] ->
                     StateT (IndexedQueue bareRep msgType msgIndex) IO ()
storeMsgsForLater ch msgs = do
  ch <- gets channel
  conv <- gets bareToMsg
  getIdx <- gets msgToIndex
  items <- gets itemsInternal
  -- Use reverse of newMsgs to maintain temporal ordering.
  let msgsWithKeys = (\m -> (getIdx m, [m])) `map` reverse msgs
  let newItems = H.fromListWith (++) msgsWithKeys
  modify $ \s -> s { itemsInternal = H.intersectionWith (++) newItems items }

fromChan :: (Eq msgIndex, Hashable msgIndex) => msgIndex -> OutChan bareRep ->
            (msgType -> msgIndex) -> (bareRep -> msgType) -> [msgType] ->
            StateT (IndexedQueue bareRep msgType msgIndex) IO msgType
fromChan idx ch getIdx conv newMsgs = do
  -- Updates state only once. May be good for performance, not really sure.
  bare <- liftIO $ readChan ch
  let msg = conv bare
  if (getIdx msg == idx) then do
    storeMsgsForLater ch newMsgs
    return msg
    else fromChan idx ch getIdx conv (msg:newMsgs)

getMsgsTimeout :: (Eq msgIndex, Hashable msgIndex) => msgIndex -> Int ->
                  StateT (IndexedQueue bareRep msgType msgIndex) IO [msgType]
getMsgsTimeout idx timeout = do
  ch <- gets channel
  conv <- gets bareToMsg
  getIdx <- gets msgToIndex
  m <- liftIO $ getChanContents ch
  bareMsgs <- liftIO $ takeUntilTime timeout m
  let msgs = conv `map` bareMsgs
  let (toUse, toStore) = ((== idx) . getIdx) `partition` msgs
  storeMsgsForLater ch toStore
  return toUse

getItemBlocking :: (Eq msgIndex, Hashable msgIndex) =>
                   msgIndex -> StateT (IndexedQueue bareRep msgType msgIndex) IO msgType
getItemBlocking idx = do
  items <- gets itemsInternal
  case H.lookup idx items of
    Just (x:xs) -> do
      modify $ \s -> s { itemsInternal = H.insert idx xs items }
      return x
    _ -> do
      ch <- gets channel
      conv <- gets bareToMsg
      getIdx <- gets msgToIndex
      fromChan idx ch getIdx conv []

getItemsTimeout :: (Eq msgIndex, Hashable msgIndex) => msgIndex -> Int ->
                   StateT (IndexedQueue bareRep msgType msgIndex) IO [msgType]
getItemsTimeout idx timeout = do
  items <- gets itemsInternal
  case H.lookup idx items of
    Just x -> do
      modify $ \s -> s { itemsInternal = H.insert idx [] items }
      res <- getMsgsTimeout idx timeout
      return $ x ++ res
    _ -> do
      getMsgsTimeout idx timeout
