import           Control.Exception             (evaluate)
import           Test.Hspec

import           Control.Concurrent            (threadDelay)
import           Control.Concurrent.Chan.Unagi
import           Control.Monad.State.Strict
import qualified Data.HashMap.Strict           as H

import           IndexedQueue

data Msg = Msg { contents :: String
               , key      :: String
               } deriving (Show, Read, Eq)

main :: IO ()
main = spec

setup :: IO (InChan String, OutChan String, IndexedQueue String Msg String)
setup = do
  (inch, outch) <- newChan
  let iq = IndexedQueue { channel = outch
                        , bareToMsg = read
                        , msgToIndex = key
                        , itemsInternal = H.empty
                        }
  return (inch, outch, iq)

testContent = "this is ** testing"
testKey     = "weird \\ /// ** key"
testMsg     = Msg { contents = testContent , key = testKey }

testMsgIndexContent i = Msg { contents = show i , key = testKey }

spec :: IO ()
spec = hspec $ do
  describe "getItemBlocking" $ do
    it "gets a single item" $ do
      (inch, outch, iq) <- setup
      _ <- writeChan inch $ show testMsg
      (recvMsg, _) <- runStateT (getItemBlocking testKey) iq
      recvMsg `shouldBe` testMsg

    it "has no other messages left in state after finishing" $ do
      (inch, outch, iq) <- setup
      _ <- writeChan inch $ show testMsg
      (_, newState) <- runStateT (getItemBlocking testKey) iq
      let items = (itemsInternal newState)
      H.keys items `shouldBe` []

  describe "getItemsTimeout" $ do
    it "gets a single item on a timeout of 1 ms" $ do
      (inch, outch, iq) <- setup
      _ <- writeChan inch $ show testMsg
      (recvMsg, _) <- runStateT (getItemsTimeout testKey 1000) iq
      recvMsg `shouldBe` [testMsg]

    it "gets 10 items on a timeout of 10 ms" $ do
      (inch, outch, iq) <- setup
      let msgs = (\i -> testMsgIndexContent i) `map` [0..10]
      mapM (writeChan inch . show) msgs
      (recvMsg, _) <- runStateT (getItemsTimeout testKey 10000) iq
      recvMsg `shouldBe` msgs

    it "has no other messages left in state after finishing" $ do
      (inch, outch, iq) <- setup
      mapM (\i -> writeChan inch $ show $ testMsgIndexContent i) [0..10]
      (_, newState) <- runStateT (getItemBlocking testKey) iq
      let items = (itemsInternal newState)
      H.keys items `shouldBe` []

  describe "addToQueue" $ do
    it "is able to add messages to queue which can be fetched" $ do
      (_, outch, iq) <- setup
      let action = do
            addToQueue testMsg
            getItemBlocking testKey
      (recvMsg, _) <- runStateT action iq
      recvMsg `shouldBe` testMsg
