import           Test.Hspec

import           Control.Concurrent                       hiding (newChan,
                                                           readChan, writeChan)
import           Control.Concurrent.Chan.Unagi.NoBlocking
import           Control.Concurrent.MVar
import           Control.Concurrent.STM.TVar
import           Control.Exception
import           Control.Monad.State.Lazy
import qualified Data.HashMap.Strict                      as H
import           Pipes
import           System.Exit
import           System.Timeout


import           IndexedQueue

data Msg = Msg { contents :: String
               , key      :: String
               } deriving (Show, Read, Eq)

main :: IO ()
main = spec

setup :: IO (InChan String, OutChan String, IndexedQueue String Msg String)
setup = do
  (inch, outch) <- newChan
  iq <- newIndexedQueue outch read key
  return (inch, outch, iq)

testContent = "this is ** testing"
testKey     = "weird \\ /// ** key"
testMsg     = Msg { contents = testContent , key = testKey }

testMsgIndexContent i = Msg { contents = show i , key = testKey }

spec :: IO ()
spec = hspec $ do

  describe "timeFilterAction" $ do
    it "Completes the IO actions as elements get available, and not after the timeout" $ do
      (inch, outch, inQueue) <- setup
      let msgs = testMsgIndexContent `map` [0..19]
      mapM (writeChan inch . show) msgs
      myMVar <- newMVar $ testMsgIndexContent (-1)

      let action v = do
            liftIO $ modifyMVar_ myMVar (\_ -> return v)
            return Nothing
      let myT = do
            -- May take up to 5 seconds.
            processLazyList 5000000 testKey inQueue action
            return ()

      let lateMessageToQueueAction = do
            -- Send a new message after 1 second.
            threadDelay 1000000
            writeChan inch . show $ testMsgIndexContent 20

      -- We kill the processing after 20 ms.
      tid <- forkIOWithUnmask $ \unmask -> unmask myT
      forkIO $ lateMessageToQueueAction
      threadDelay 100000 -- Wait 20ms
      killThread tid

      -- The final message should not have been the one sent after 1 second.
      finalVal <- readMVar myMVar
      (contents finalVal) `shouldBe` "19"


  describe "getItemsBlocking" $ do
    it "returns all the messages lumped together, after the timeout" $ do
      (inch, outch, iq) <- setup
      let msgs = testMsgIndexContent `map` [0..99]
      mapM (writeChan inch . show) msgs
      (res, niq) <- getItemsBlocking 10000 testKey iq
      res `shouldBe` msgs

    it "works well even when message types are interleaved" $ do
      (inch, outch, iq) <- setup
      let msgs = (\i -> Msg { contents = show i, key = testKey }) `map` [0..99]
      let otherMsgs = (\i -> Msg { contents = "Fake" ++ show i, key = "Key" ++ show i })
                      `map` [0..99]
      let interleave xs ys = concat (zipWith (\x y -> [x]++[y]) xs ys)
      let sendingMsgs = interleave msgs otherMsgs
      mapM (writeChan inch . show) sendingMsgs
      (res, niq) <- getItemsBlocking 100000 testKey iq
      res `shouldBe` msgs

    it "fetching two different keys one-after-the-other works" $ do
      (inch, outch, iq) <- setup
      let msgs = (\i -> Msg { contents = show i, key = "Key1" }) `map` [0..99]
      let otherMsgs = (\i -> Msg { contents = "Fake" ++ show i, key = "Key2"})
                      `map` [0..99]
      let interleave xs ys = concat (zipWith (\x y -> [x]++[y]) xs ys)
      let sendingMsgs = interleave msgs otherMsgs
      mapM (writeChan inch . show) sendingMsgs
      (res, niq) <- getItemsBlocking 50000 "Key1" iq
      (res2, niq2) <- getItemsBlocking 50000 "Key2" niq
      res2 `shouldBe` otherMsgs
