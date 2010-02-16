module Search (Triple, Search, dispatch, searchMe, searchChild, searchFamily) where

import Control.Applicative
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map hiding (Map)
import Data.Ord
import Database.HDBC
import Database.HDBC.Sqlite3
import Msg
import Sql
import System.FilePath

----------------------------------------------------------------

type Triple = (ID,FilePath,FilePath)
type Search = Connection -> ID -> FilePath -> IO [Msg]

----------------------------------------------------------------

dispatch :: Search -> Triple -> IO [Msg]
dispatch func (mid,db,dir) = handleSqlError $ do
    conn <- connectSqlite3 db
    msgs <- func conn mid dir
    disconnect conn
    return msgs

----------------------------------------------------------------

searchMe :: Search
searchMe conn mid dir = chooseOne dir <$> selectByID conn mid

----------------------------------------------------------------

searchChild :: Search
searchChild conn mid dir = chooseOne dir <$> selectByPaID conn [mid]

----------------------------------------------------------------

searchFamily :: Search
searchFamily conn mid dir = sortBy (comparing date) <$> findFamily
  where
    findFamily = findRoot conn mid mid >>= findDescendants conn dir

data ParentError = NoEntry | NoPid

getPaid :: Connection -> ID -> IO (Either ParentError ID)
getPaid conn mid = getPid <$> selectByID conn mid
  where
    getPid []     = Left NoEntry
    getPid (e:_)
      | pid == "" = Left NoPid
      | otherwise = Right pid
      where
        pid = paid e

findRoot :: Connection -> ID -> ID -> IO ID
findRoot conn previd mid =
    getPaid conn mid >>= either terminate (findRoot conn mid)
  where
    terminate NoEntry = return previd
    terminate NoPid   = return mid

type Hash = Map ID Msg

findDescendants :: Connection -> FilePath -> ID -> IO [Msg]
findDescendants conn dir rtid = do
    root <- head . chooseOne dir <$> selectByID conn rtid
    let mmap = Map.insert rtid root Map.empty
    findChildren ([rtid],mmap)
  where
    findChildren :: ([ID],Hash) -> IO [Msg]
    findChildren (ids,hash) = selectByPaID conn ids >>= findChildren'
      where
        findChildren' []    = return (Map.elems hash)
        findChildren' msgs  = findChildren $ pushChildren hash msgs []

    pushChildren :: Hash -> [Msg] -> [ID] -> ([ID],Hash)
    pushChildren hash [] ids = (ids, hash)
    pushChildren hash (m:ms) ids
        | Map.notMember mid hash = pushChildren hash' ms (mid:ids)
        | mdir == dir            = pushChildren hash' ms ids
                                   -- insert overwrites the value
        | otherwise              = pushChildren hash  ms ids
      where
        hash' = Map.insert mid m hash
        mdir = (takeDirectory.path) m
        mid = myid m

----------------------------------------------------------------
-- to express failure, the empty list is used

chooseOne :: FilePath -> [Msg] -> [Msg]
chooseOne _ [] = [] -- failure
chooseOne "" (m:_) = [m]
chooseOne dir msgs@(m:_)
  | null sames = [m]
  | otherwise  = [head sames]
  where
    sames = filter sameDir msgs
    sameDir x = (takeDirectory.path) x == dir
