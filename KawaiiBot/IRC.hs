{-
A lewd IRC bot that does useless things.
Copyright (C) 2012 Shou

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
-}

{-# LANGUAGE DoAndIfThenElse #-}
{-# OPTIONS_HADDOCK prune #-}

module KawaiiBot.IRC where


import KawaiiBot.Bot
import KawaiiBot.Types
import KawaiiBot.Utils

import Control.Applicative
import Control.Concurrent
import Control.Exception as E
import Control.Monad hiding (join)
import qualified Control.Monad as M
import Control.Monad.Reader hiding (join)

import Data.List
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Time.Format
import Data.Maybe
import Data.String.Utils (split, join, strip)

import Network

import System.Directory
import System.IO
import System.Locale
import System.Random (randomRIO)


-- | Writes to the core which then passes it to an IRC server.
ircwrite :: Handle -> String -> Memory ()
ircwrite h str = do
    debug <- asks (verbosityC . getConfig)
    meta <- asks getMeta
    let server = getServer meta
        message = concat ["serverwrite ", server, ":", str]
    e <- liftIO $ try (hPutStrLn h message) :: Memory (Either SomeException ())
    case e of
        Right _ -> when (debug > 1) . liftIO . putStrLn $ "<- " ++ message
        Left e -> when (debug > 0) . liftIO $ print e

-- | Writes to the core.
corewrite :: Handle -> String -> Memory ()
corewrite h str = do
    debug <- asks (verbosityC . getConfig)
    let message = "<Core>" ++ ":" ++ str
    e <- liftIO $ try (hPutStrLn h str) :: Memory (Either SomeException ())
    case e of
        Right _ -> when (debug > 1) . liftIO . putStrLn $ "<- " ++ message
        Left e -> when (debug > 0) . liftIO $ print e

logWrite :: String -> Memory ()
logWrite msg = do
    meta <- asks getMeta
    logsPath <- asks (logsPathC . getConfig)
    verbosity <- asks (verbosityC . getConfig)
    time <- do
        utc <- liftIO $ getCurrentTime
        return $ formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" utc
    let writeLog :: Memory (Either SomeException ())
        writeLog = liftIO . try $ do
            let serverurl = getServer meta
                dest = getDestino meta
                path = logsPath ++ serverurl ++ " " ++ dest
                nick = getUsernick meta
                full = '\n' : intercalate "\t" [time,nick,msg]
                tmpfile = "/tmp/" ++ serverurl ++ " " ++ dest
            E.catch (copyFile path tmpfile) $ \e -> do
                evaluate (e :: SomeException)
                writeFile path ""
                copyFile path tmpfile
            appendFile tmpfile full
            copyFile tmpfile path
    e <- writeLog
    case e of
        Right _ -> return ()
        Left e -> when (verbosity > 0) . liftIO $ print e

-- | Reinitialize an event.
eventInit :: Event -> Memory Event
eventInit (Event f r ti c s te) = do
    time <- liftIO $ fmap realToFrac getPOSIXTime
    time' <- liftIO $ fmap (time +) r
    return $ Event f r time' c s te

-- | Timed event function.
event :: Handle -> Memory ()
event h = do
    events <- asks (eventsC . getConfig)
    currentTime <- liftIO $ fmap realToFrac getPOSIXTime
    events' <- forM events $ \event -> do
        let bool = currentTime >= eventTime event
            temp = eventTemp event
        cbool <- liftIO $ chance (eventChance event)
        case () of
          _ | bool && cbool -> do
                let servers :: [Server]
                    servers = eventServers event
                    metas :: [Meta]
                    metas = concat . (`map` servers) $
                        \(Server _ server _ _ _ channels _ _) ->
                            case channels of
                                Blacklist chans -> []
                                Whitelist chans ->
                                    (`map` chans) $ \chan ->
                                        Meta chan "Anon" "" "" [] server temp
                forM_ metas $ \meta -> do
                    text <- local (injectMeta meta) $ eventFunc event
                    unless (null text) $ do
                        local (injectMeta meta) $ do
                            ircwrite h $ genPrivmsg meta text
                eventInit event
            | not bool -> return event
            | not cbool -> eventInit event
    liftIO . threadDelay $ 10^6
    local (modConfig $ injectEvents events') $ event h
  where genPrivmsg (Meta dest _ _ _ _ _ _) t = "PRIVMSG " ++ dest ++ " :" ++ t
        chance :: Double -> IO Bool
        chance n = do
            let n' = if n > 1.0 then 1.0 else n
            i <- randomRIO (0.0, 1.0)
            return (n >= i)

-- | Recursive function that gets a line from kawaiibot-core and parses it.
listenLoop :: Handle -> Memory ()
listenLoop h = do
    s <- liftIO $ hGetLine h
    let arg = takeWhile (`notElem` " :") s
    if arg `elem` coreArgs then do
        liftIO . putStrLn $ "-> " ++ s
        mc <- parseCore h s
        local (\_ -> mc) $ listenLoop h
    else do
        parseIRC h s
        listenLoop h
  where coreArgs = [ "getservers"
                   , "getnick"
                   , "serverjoin"
                   , "serverquit"
                   , "getuserlist"
                   ]

-- | Parse a Core message
parseCore :: Handle -- ^ Core server handle
          -> String -- ^ message received
          -> Memory MetaConfig
parseCore h bs = do
    debug <- asks (verbosityC . getConfig)
    mc@(MetaConfig meta config) <- ask
    let (sCmd : xs) = concat (split " " <$> split ":" bs)
        sArgs = xs
    when (debug > 1) . liftIO . print $ sCmd : sArgs
    case sCmd of
        "getuserlist" -> do
            let margs :: Maybe (String, String, [String])
                margs = do
                    (server : channel : users) <- Just sArgs
                    return (server, channel, users)
            case margs of
                Just (se, ch, us) -> do
                    let servs = injectServerUserlist (serversC config) se ch us
                        conf = mapConfigServers (const servs) config
                    return $ MetaConfig meta conf
                -- Not enough arguments (this isn't supposed to ever happen)
                Nothing -> return mc
        -- Fallback
        _ -> return mc

-- | Parse an IRC message.
parseIRC :: Handle -- ^ Core server handle
         -> String -- ^ message received
         -> Memory ()
parseIRC h bs = do
    debug <- asks (verbosityC . getConfig)
    meta <- asks getMeta
    let nick = getUsernick meta
        sFull :: [String]
        sFull = ":" `split` bs
        sMsg  = ":" `join` drop 2 sFull
        sArgs = map strip . splits "!@ " . concat . take 1 $ drop 1 sFull
        meta' = sFull !! 0 `injectServ` meta
    when (debug > 1) . liftIO . putStrLn $ show sArgs ++ ' ' : sMsg
    local (injectMeta meta') $ parseMsg h (sArgs, sMsg)
  where parseMsg :: Handle -> ([String], String) -> Memory ()
        parseMsg h (args, msg)
            | isCmd args 3 "PRIVMSG" = do -- Interpret message and respond if
                meta <- asks getMeta      -- anything is returned from `parser'
                config <- asks getConfig
                let nick = args !! 0
                    name = args !! 1
                    host = args !! 2
                    act = args !! 3
                    dest = args !! 4
                    channels = getChannels meta
                    serverurl = getServer meta
                    ulist = getUserlist $ getConfigMeta config serverurl dest

                    meta' = Meta dest nick name host channels serverurl ulist

                local (injectMeta meta') $ do
                    meta <- asks getMeta
                    msgLogging <- asks (msgLoggingC . getConfig)

                    allowThen allowTitle $ do -- URL fetching
                        let urls = filter (isPrefixOf "http") $ words msg
                        forkMe . forM_ urls $ \url -> do
                            title' <- fmap fromMsg $ title url
                            let titleMsg = unwords [ "PRIVMSG"
                                                   , dest
                                                   , ":\ETX5→\ETX"
                                                   , title'
                                                   ]
                            unless (null title') $ ircwrite h titleMsg
                        return EmptyMsg
                    post <- parser msg
                    let mAct = if isChannelMsg post
                            then "PRIVMSG " ++ dest
                            else "PRIVMSG " ++ nick
                        msg' = fromMsg post

                    when msgLogging $ do -- logging
                        logWrite msg

                    unless (null msg') $ do
                        ircwrite h $ mAct ++ " :" ++ msg'
                        kawaiinick <- getServerNick
                        let kawaiimeta = emptyMeta { getUsernick = kawaiinick
                                                   , getDestino = dest
                                                   , getServer = serverurl
                                                   }
                        local (injectMeta kawaiimeta) $ do
                            logWrite msg'

                    return ()
            | isCmd args 3 "INVITE" = do -- Join a channel on invite
                meta <- asks getMeta
                let nick = args !! 0
                    name = args !! 1
                    host = args !! 2
                    act = args !! 3
                    dest = args !! 4
                    channels = getChannels meta
                    serverurl = getServer meta
                    temp = getUserlist meta

                    meta' = Meta dest nick name host channels serverurl temp

                allowedChans <- do
                    let servers = serversC . getConfig
                        mserver = (`findServer` serverurl) . servers
                    asks (fmap allowedChannels . mserver)
                case allowedChans of
                    Just (Blacklist xs) -> do
                        if msg `elem` xs then do
                            ircwrite h $ "JOIN " ++ msg
                        else do
                            let msg = "Your channel is blacklisted."
                            ircwrite h $ "PRIVMSG " ++ dest ++ " :" ++ msg
                    Just (Whitelist xs) -> do
                        if msg `elem` xs then do
                            ircwrite h $ "JOIN " ++ msg
                        else do
                            let msg = "Your channel is not whitelisted."
                            ircwrite h $ "PRIVMSG " ++ dest ++ " :" ++ msg
                    Nothing -> return ()
                return ()
            | isCmd args 3 "KICK" = do 
                meta <- asks getMeta
                let dest = args !! 4
                    serverurl = getServer meta

                corewrite h $ concat ["getuserlist ", serverurl, ":", dest]
            | isCmd args 3 "PART" = do
                meta <- asks getMeta
                let nick = args !! 0
                    dest = args !! 4
                    serverurl = getServer meta

                corewrite h $ concat ["getuserlist ", serverurl, ":", dest]
            | isCmd args 3 "JOIN" = do
                meta <- asks getMeta
                let nick = args !! 0
                    dest = msg
                    serverurl = getServer meta

                corewrite h $ concat ["getuserlist ", serverurl, ":", dest]
                varPath <- asks (variablePathC . getConfig)
                svars <- liftIO $ lines <$> readFile varPath
                let mvar :: [Variable]
                    mvar = do
                        v <- svars
                        let mvars = maybeRead v
                        guard $ isJust mvars
                        let var = fromJust mvars
                        guard $ readableReminder serverurl dest nick var
                        return var
                case length mvar of
                  0 -> return ()
                  1 -> ircwrite h $ unwords [ "PRIVMSG"
                                         , dest
                                         , ':' : nick ++ ":"
                                         , varContents $ head mvar
                                         ]
                  _ ->
                    ircwrite h $ unwords [ "PRIVMSG"
                                      , dest
                                      , ':' : nick ++ ":"
                                      , "You have " ++ show (length mvar)
                                      , "reminders:"
                                      , unwords $ map varName mvar
                                      ]
            | isCmd args 3 "QUIT" = do 
                meta <- asks getMeta
                servers <- asks (serversC . getConfig)
                let nick = args !! 0
                    serverurl = getServer meta

                let mchans :: Maybe [String]
                    mchans = listToMaybe $ do
                        s <- servers
                        guard $ serverURL s == serverurl
                        return $ do
                            m <- serverMetas s
                            return $ getDestino m
                    chans = fromJust $ mchans <|> Just []

                forM_ chans $ \chan -> do
                    corewrite h $ concat ["getuserlist ", serverurl, ":", chan]
            | isCmd args 3 "NICK" = do 
                meta <- asks getMeta
                servers <- asks (serversC . getConfig)
                let nick = args !! 0
                    serverurl = getServer meta

                let mchans :: Maybe [String]
                    mchans = listToMaybe $ do
                        s <- servers
                        guard $ serverURL s == serverurl
                        return $ do
                            m <- serverMetas s
                            return $ getDestino m
                    chans = fromJust $ mchans <|> Just []

                forM_ chans $ \chan -> do
                    corewrite h $ concat ["getuserlist ", serverurl, ":", chan]
            | isCmd args 3 "MODE" = do 
                let nick = args !! 0
                    dest = args !! 4
                    mode = args !! 5

                return ()
            | isCmd args 1 "353" = do -- Receive nick list
                meta <- asks getMeta
                let dest = args !! 4
                    serverurl = getServer meta

                corewrite h $ concat ["getuserlist ", serverurl, ":", dest]
            | otherwise = do -- Fallback
                return ()
        isCmd args n x | length args >= 3 = args !! 3 == x
                       | otherwise = False

-- | Connects to kawaiibot-core.
serverConnect :: Memory ()
serverConnect = do
    h <- liftIO $ do
        h <- connectTo "localhost" (PortNumber $ fromIntegral 3737)
        hSetEncoding h utf8
        hSetBuffering h LineBuffering
        hSetNewlineMode h (NewlineMode CRLF CRLF)
        forkIO . forever $ getLine >>= \s -> unless (null s) $ hPutStrLn h s
        return h
    events <- asks (eventsC . getConfig)
    events' <- mapM eventInit events
    local (modConfig $ injectEvents events') (forkMe $ event h)
    listenLoop h
