{-# LANGUAGE QuasiQuotes, TemplateHaskell, TypeFamilies, OverloadedStrings #-}

import Yesod.Core                   as YC
import Yesod.WebSockets             as YW
import qualified Data.Text.Lazy     as TL
import qualified Control.Monad      as CM
import Control.Monad.Trans.Reader   as R
import Control.Concurrent (threadDelay)
import Data.Time                    as T
import Data.Conduit                 as C
import Data.Conduit.List            as CL
import Data.Monoid ((<>))
import Control.Concurrent.STM.Lifted as L
import Data.Text (Text)

data App = App (TChan Text)

--mapM_C :: (MonoFoldable c, Monad m) => (Element c -> m ()) -> Consumer c m ()
--mapM_C = CL.mapM_ . CM.mapM_

instance Yesod App

mkYesod "App" [parseRoutes|
/ HomeR GET
|]

chatApp :: WebSocketsT Handler ()
chatApp = do
    YW.sendTextData ("Welcome to the chat server, please enter your name." :: Text)
    name <- YW.receiveData
    YW.sendTextData $ "Welcome, " <> name
    App writeChan <- YC.getYesod
    readChan <- L.atomically $ do
        L.writeTChan writeChan $ name <> " has joined the chat"
        L.dupTChan writeChan
    YW.race_
        (CM.forever $ L.atomically (L.readTChan readChan) >>= YW.sendTextData)
        (YW.sourceWS $$ CL.mapM_ (\msg ->
            L.atomically $ writeTChan writeChan $ name <> ": " <> msg))

getHomeR :: Handler Html
getHomeR = do
    YW.webSockets chatApp
    YC.defaultLayout $ do
        [whamlet|
            <div #output>
            <form #form>
                <input #input autofocus>
        |]
        YC.toWidget [lucius|
            \#output {
                width: 600px;
                height: 400px;
                border: 1px solid black;
                margin-bottom: 1em;
                p {
                    margin: 0 0 0.5em 0;
                    padding: 0 0 0.5em 0;
                    border-bottom: 1px dashed #99aa99;
                }
            }
            \#input {
                width: 600px;
                display: block;
            }
        |]
        YC.toWidget [julius|
            var url = document.URL,
                output = document.getElementById("output"),
                form = document.getElementById("form"),
                input = document.getElementById("input"),
                conn;

            url = url.replace("http:", "ws:").replace("https:", "wss:");
            conn = new WebSocket(url);

            conn.onmessage = function(e) {
                var p = document.createElement("p");
                p.appendChild(document.createTextNode(e.data));
                output.appendChild(p);
            };

            form.addEventListener("submit", function(e){
                conn.send(input.value);
                input.value = "";
                e.preventDefault();
            });
        |]

main :: IO ()
main = do
    chan <- L.atomically L.newBroadcastTChan
    YC.warp 3000 $ App chan