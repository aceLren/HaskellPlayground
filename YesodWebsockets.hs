{-# LANGUAGE QuasiQuotes, TemplateHaskell, TypeFamilies, OverloadedStrings, GADTs #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts, GeneralizedNewtypeDeriving #-}

import qualified Yesod                          as Y
import qualified Yesod.Core                     as YC
import qualified Yesod.WebSockets               as YW
import qualified Database.MongoDB               as MD
import qualified Database.Persist               as P
import qualified Database.Persist.TH            as TH
import qualified Language.Haskell.TH.Syntax     as TS
import qualified Database.Persist.MongoDB       as MP
import qualified Data.Text.Lazy                 as TL
import qualified Control.Monad                  as CM
import qualified Control.Monad.Trans.Reader     as R
import Control.Concurrent (threadDelay)
import qualified Data.Time                      as T
import qualified Data.Conduit                   as C
import qualified Data.Conduit.List              as CL
import Data.Monoid ((<>))
import qualified Control.Concurrent.STM.Lifted  as L
import Data.Text (Text)
import Debug.Trace

data App = App (L.TChan Text) MP.MongoConf MP.ConnectionPool

instance YC.Yesod App
instance Y.YesodPersist App where
    type YesodPersistBackend App = MP.Action
    runDB act = do
        App ch conf pool <- YC.getYesod
        MP.runPool conf act pool

TH.share [TH.mkPersist (TH.mkPersistSettings (TS.ConT ''MP.MongoBackend)) { TH.mpsGeneric = False }, 
          TH.mkMigrate "migrateAll"] [TH.persistLowerCase|
User
    name Text Eq
    msg Text

Other
    name Text
    deriving Show Eq Read
|]

YC.mkYesod "App" [YC.parseRoutes|
/ HomeR GET
|]

chatApp :: YW.WebSocketsT Handler ()
chatApp = do
    YW.sendTextData ("Welcome to the chat server, please enter your name." :: Text)
    name <- YW.receiveData
    YW.sendTextData $ "Welcome, " <> name
    App writeChan conf pool <- YC.getYesod

    YC.lift (Y.runDB $ MP.insert $ User "ace" "this is a msg")

    readChan <- L.atomically $ do
        -- First tell everyone already here this guy has joined
        L.writeTChan writeChan $ name <> " has joined the chat"
        -- Then duplicate, this is the only way to read
        L.dupTChan writeChan
    YW.race_ -- Both of these are forever
        (CM.forever $ L.atomically (L.readTChan readChan) >>= YW.sendTextData)
        (YW.sourceWS C.$$ CL.mapM_ (\msg -> do
            L.atomically $ L.writeTChan writeChan $ name <> ": " <> msg
            CM.void $ YC.lift (Y.runDB $ MP.insert $ User name msg) ))

getHomeR :: Handler YC.Html
getHomeR = do
    Y.runDB $ MP.insert $ User "ace" "this is a msg"
    --trace "\nSocketTime!!\n" 
    YW.webSockets chatApp

    --trace "\nLayoutTime!!\n" 
    YC.defaultLayout $ do
        [YC.whamlet|
            <div #output>
            <form #form>
                <input #input autofocus>
        |]
        YC.toWidget [YC.lucius|
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
        YC.toWidget [YC.julius|
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
    let conf = MP.defaultMongoConf "yesodTest"
    MP.withConnection conf $ \pool ->
        YC.warp 3000 $ App chan conf pool
    