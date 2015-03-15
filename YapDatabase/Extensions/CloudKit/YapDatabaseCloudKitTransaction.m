#import "YapDatabaseCloudKitPrivate.h"
#import "YapDatabasePrivate.h"
#import "YDBCKRecord.h"
#import "YDBCKAttachRequest.h"
#import "YDBCKRecordKeysRow.h"

#import "YapDatabaseString.h"
#import "YapDatabaseLogging.h"

#import "NSDictionary+YapDatabase.h"

#import <CommonCrypto/CommonDigest.h>

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_VERBOSE | YDB_LOG_FLAG_TRACE;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif
#pragma unused(ydbLogLevel)

static NSString *const ExtKey_classVersion = @"classVersion";
static NSString *const ExtKey_versionTag   = @"versionTag";

typedef NS_OPTIONS(NSUInteger, YDBCKProcessRecordBitMask) {
	YDBCK_skipUploadRecord   = 1 << 0,
	YDBCK_skipUploadDeletion = 1 << 1,
	YDBCK_remoteDeletion     = 1 << 2,
	YDBCK_remoteMerge        = 1 << 3,
};

@implementation YapDatabaseCloudKitTransaction

- (id)initWithParentConnection:(YapDatabaseCloudKitConnection *)inParentConnection
           databaseTransaction:(YapDatabaseReadTransaction *)inDatabaseTransaction
{
	if ((self = [super init]))
	{
		parentConnection = inParentConnection;
		databaseTransaction = inDatabaseTransaction;
	}
	return self;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Extension Lifecycle
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method is called to create any necessary tables,
 * as well as populate the view by enumerating over the existing rows in the database.
 * 
 * Return YES if completed successfully, or if already prepared.
 * Return NO if some kind of error occured.
**/
- (BOOL)createIfNeeded
{
	YDBLogAutoTrace();
	
	// Capture NEW values
	//
	// classVersion - the internal version number of YapDatabaseView implementation
	// versionTag - user specified versionTag, used to force upgrade mechanisms
	
	int classVersion = YAP_DATABASE_CLOUD_KIT_CLASS_VERSION;
	
	NSString *versionTag = parentConnection->parent->versionTag;
	
	// Fetch OLD values
	//
	// - hasOldClassVersion - will be YES if the extension exists from a previous run of the app
	
	int oldClassVersion = 0;
	BOOL hasOldClassVersion = [self getIntValue:&oldClassVersion forExtensionKey:ExtKey_classVersion persistent:YES];
	
	NSString *oldVersionTag = [self stringValueForExtensionKey:ExtKey_versionTag persistent:YES];
	
	if (!hasOldClassVersion)
	{
		// First time registration
		
		if (![self createTables]) return NO;
		if (![self createNewMasterChangeQueue]) return NO;
		if (![self populateTables]) return NO;
		
		[self setIntValue:classVersion forExtensionKey:ExtKey_classVersion persistent:YES];
		[self setStringValue:versionTag forExtensionKey:ExtKey_versionTag persistent:YES];
	}
	else if (oldClassVersion != classVersion)
	{
		// Upgrading from older codebase
		//
		// Reserved for potential future use.
		// Code would likely need to do something similar to the following:
		//
		// - restoreMasterChangeQueue
		// - migrate table(s)
		// - repopulateTables
		
		NSAssert(NO, @"Attempting invalid upgrade path !");
		return NO;
	}
	else if (![versionTag isEqualToString:oldVersionTag])
	{
		// Handle user-indicated change
		
		if (![self restoreMasterChangeQueue]) return NO;
		if (![self repopulateTables]) return NO;
		
		[self setStringValue:versionTag forExtensionKey:ExtKey_versionTag persistent:YES];
	}
	else
	{
		// Restoring an up-to-date extension from a previous run.
		
		if (![self restoreMasterChangeQueue]) return NO;
	}
	
	return YES;
}

/**
 * This method is called to prepare the transaction for use.
 *
 * Remember, an extension transaction is a very short lived object.
 * Thus it stores the majority of its state within the extension connection (the parent).
 *
 * Return YES if completed successfully, or if already prepared.
 * Return NO if some kind of error occured.
**/
- (BOOL)prepareIfNeeded
{
	YDBLogAutoTrace();
	
	// Nothing to do here for this extension.
	
	return YES;
}

- (BOOL)createTables
{
	YDBLogAutoTrace();
	
	sqlite3 *db = databaseTransaction->connection->db;
	
	NSString *mappingTableName    = [self mappingTableName];
	NSString *recordTableName     = [self recordTableName];
	NSString *recordKeysTableName = [self recordKeysTableName];
	NSString *queueTableName      = [self queueTableName];
	
	int status;
	
	// Mapping Table
	//
	// | rowid | recordTable_hash |
	
	YDBLogVerbose(@"Creating cloudKit table for registeredName(%@): %@", [self registeredName], mappingTableName);
	
	NSString *createMappingTable = [NSString stringWithFormat:
	  @"CREATE TABLE IF NOT EXISTS \"%@\""
	  @"(\"rowid\" INTEGER PRIMARY KEY,"
	  @" \"recordTable_hash\" TEXT NOT NULL"
	  @" );", mappingTableName];
	
	NSString *createMappingTableIndex = [NSString stringWithFormat:
	  @"CREATE INDEX IF NOT EXISTS \"recordTable_hash\" ON \"%@\" (\"recordTable_hash\");", mappingTableName];
	
	YDBLogVerbose(@"%@", createMappingTable);
	status = sqlite3_exec(db, [createMappingTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating table (%@): %d %s",
		            THIS_METHOD, mappingTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	YDBLogVerbose(@"%@", createMappingTableIndex);
	status = sqlite3_exec(db, [createMappingTableIndex UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating index on table (%@): %d %s",
					THIS_METHOD, mappingTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	// Record Table
	//
	// | hash | ownerCount | databaseIdentifier | recordKeys_hash | record |
	
	YDBLogVerbose(@"Creating cloudKit table for registeredName(%@): %@", [self registeredName], recordTableName);
		
	NSString *createRecordTable = [NSString stringWithFormat:
	  @"CREATE TABLE IF NOT EXISTS \"%@\""
	  @" (\"hash\" TEXT PRIMARY KEY NOT NULL," // custom hash of CKRecordID & databaseIdentifier (for lookups)
	  @"  \"databaseIdentifier\" TEXT,"        // user specified databaseIdentifier (null for default)
	  @"  \"ownerCount\" INTEGER,"             // used for mapped records
	  @"  \"recordKeys_hash\" TEXT NOT NULL,"  // CKRecord.allKeys (optimzed storage in recordKeys table)
	  @"  \"record\" BLOB"                     // CKRecord (system fields only for mapped records)
	  @" );", recordTableName];
	
	YDBLogVerbose(@"%@", createRecordTable);
	status = sqlite3_exec(db, [createRecordTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating table (%@): %d %s",
		            THIS_METHOD, recordTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	// RecordKeys Table
	//
	// | hash | allKeys |
	
	YDBLogVerbose(@"Creating cloudKit table for registeredName(%@): %@",[self registeredName], recordKeysTableName);
	
	NSString *createRecordKeysTable = [NSString stringWithFormat:
	  @"CREATE TABLE IF NOT EXISTS \"%@\""
	  @" (\"hash\" TEXT PRIMARY KEY NOT NULL,"
	  @"  \"keys\" BLOB"
	  @" );", recordKeysTableName];
	
	YDBLogVerbose(@"%@", createRecordKeysTable);
	status = sqlite3_exec(db, [createRecordKeysTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating table (%@): %d %s",
		            THIS_METHOD, recordKeysTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	// Queue Table
	//
	// | uuid | prev | deletedRecordIDs | modifiedRecords |
	
	YDBLogVerbose(@"Creating cloudKit table for registeredName(%@): %@", [self registeredName], queueTableName);
	
	NSString *createQueueTable = [NSString stringWithFormat:
	    @"CREATE TABLE IF NOT EXISTS \"%@\""
	    @" (\"uuid\" TEXT PRIMARY KEY NOT NULL,"
	    @"  \"prev\" TEXT,"
		@"  \"databaseIdentifier\" TEXT,"
	    @"  \"deletedRecordIDs\" BLOB,"
		@"  \"modifiedRecords\" BLOB"
	    @" );", queueTableName];
	
	YDBLogVerbose(@"%@", createQueueTable);
	status = sqlite3_exec(db, [createQueueTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating table (%@): %d %s",
		            THIS_METHOD, queueTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	return YES;
}

/**
 * Shortcut when creating an extension for the first time.
 * (No need to restore the masterChangeQueue when we know it doesn't exist.)
**/
- (BOOL)createNewMasterChangeQueue
{
	parentConnection->parent->masterQueue = [[YDBCKChangeQueue alloc] initMasterQueue];
	
	return YES;
}

/**
 * This method restores the masterChangeQueue from a previous app run.
 * This allows us to pick up where we left off, and ensure all requested changes make it up to the cloud.
**/
- (BOOL)restoreMasterChangeQueue
{
	YDBLogAutoTrace();
	
	// Enumerate the rows in the queue table,
	// and extract the row information into YDBCKChangeSet objects.
	
	sqlite3 *db = databaseTransaction->connection->db;
	sqlite3_stmt *statement;
	int status;
	
	NSMutableDictionary *changeSetsDict = [NSMutableDictionary dictionaryWithCapacity:1];
	YDBCKChangeSet *lastChangeSetFromEnumeration = nil;
	
	NSString *enumerate = [NSString stringWithFormat:
	  @"SELECT \"uuid\", \"prev\", \"databaseIdentifier\", \"deletedRecordIDs\", \"modifiedRecords\" FROM \"%@\";",
	  [self queueTableName]];
	
	int col_uuid             = SQLITE_COL_START + 0;
	int col_prev             = SQLITE_COL_START + 1;
	int col_dbid             = SQLITE_COL_START + 2;
	int col_deletedRecordIDs = SQLITE_COL_START + 3;
	int col_modifiedRecords  = SQLITE_COL_START + 4;
	
	status = sqlite3_prepare_v2(db, [enumerate UTF8String], -1, &statement, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@: Error creating prepared statement: %d %s", THIS_METHOD, status, sqlite3_errmsg(db));
		
		return NO;
	}
	
	while ((status = sqlite3_step(statement)) == SQLITE_ROW)
	{
		NSString *uuid = nil;
		NSString *prev = nil;
		NSString *dbid = nil;
		NSData *blob1 = nil;
		NSData *blob2 = nil;
		
		const unsigned char *_uuid = sqlite3_column_text(statement, col_uuid);
		int _uuidLen = sqlite3_column_bytes(statement, col_uuid);
		
		uuid = [[NSString alloc] initWithBytes:_uuid length:_uuidLen encoding:NSUTF8StringEncoding];
		
		int column_type;
		
		column_type = sqlite3_column_type(statement, col_prev);
		if (column_type != SQLITE_NULL)
		{
			const unsigned char *_prev = sqlite3_column_text(statement, col_prev);
			int _prevLen = sqlite3_column_bytes(statement, col_prev);
			
			prev = [[NSString alloc] initWithBytes:_prev length:_prevLen encoding:NSUTF8StringEncoding];
		}
		
		column_type = sqlite3_column_type(statement, col_dbid);
		if (column_type != SQLITE_NULL)
		{
			const unsigned char *_dbid = sqlite3_column_text(statement, col_dbid);
			int _dbidLen = sqlite3_column_bytes(statement, col_dbid);
			
			dbid = [[NSString alloc] initWithBytes:_dbid length:_dbidLen encoding:NSUTF8StringEncoding];
		}
		
		column_type = sqlite3_column_type(statement, col_deletedRecordIDs);
		if (column_type != SQLITE_NULL)
		{
			const void *_blob1 = sqlite3_column_blob(statement, col_deletedRecordIDs);
			int _blob1Len = sqlite3_column_bytes(statement, col_deletedRecordIDs);
			
			blob1 = [NSData dataWithBytesNoCopy:(void *)_blob1 length:_blob1Len freeWhenDone:NO];
		}
		
		column_type = sqlite3_column_type(statement, col_modifiedRecords);
		if (column_type != SQLITE_NULL)
		{
			const void *_blob2 = sqlite3_column_blob(statement, col_modifiedRecords);
			int _blob2Len = sqlite3_column_bytes(statement, col_modifiedRecords);
			
			blob2 = [NSData dataWithBytesNoCopy:(void *)_blob2 length:_blob2Len freeWhenDone:NO];
		}
		
		YDBCKChangeSet *changeSet = [[YDBCKChangeSet alloc] initWithUUID:uuid
		                                                            prev:prev
		                                              databaseIdentifier:dbid
		                                                deletedRecordIDs:blob1
		                                                 modifiedRecords:blob2];
		
		[changeSetsDict setObject:changeSet forKey:uuid];
		lastChangeSetFromEnumeration = changeSet;
	}
	
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
					status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_finalize(statement);
	statement = NULL;
	
	// Put the changeSets into the correct order.
	//
	// We have a reverse linked-list, where every element points to the previous one.
	// The first item in the linked-list will point to an item that no longer exists.
	// That is, when an item is removed from the front of the linked list,
	// we don't attempt to set next.prev = nil. (That would be unnecessary disk IO.)
	//
	// Also note that it's highly likely that the changeSets were enumerated in-order by sqlite.
	// This is because sqlite likely enumerated the rows by rowid,
	// and its very very likely the the highest rowid is the most recently inserted changeSet.
	//
	// So here's our algorithm:
	//
	// - Start with the lastChangeSetFromEnumeration.
	// - Add it to the array.
	// - Work backwards, looping, and adding prevChangeSet to the front of the array.
	// - At this point we have an array that contains the range [firstChangeSet, lastChangeSetFromEnumeration].
	// - If lastChangeSetFromEnumeration was indeed the lastChangeSet, then we're done.
	// - Otherwise we grab another changeSet from the dictionary,
	// - add it to the end of the array, and then begin working backwards again.
	
	NSMutableArray *orderedChangeSets = [NSMutableArray arrayWithCapacity:[changeSetsDict count]];
	
	YDBCKChangeSet *changeSet = lastChangeSetFromEnumeration;
	NSUInteger offset = 0;
	
	while (changeSet != nil)
	{
		// Add the changeSet to the end of the ordered array (and remove from dictionary)
		[orderedChangeSets addObject:changeSet];
		[changeSetsDict removeObjectForKey:changeSet.uuid];
		
		// Work backwards, filling in all previous changeSets
		do
		{
			changeSet = [changeSetsDict objectForKey:changeSet.prev];
			if (changeSet)
			{
				[orderedChangeSets insertObject:changeSet atIndex:offset];
				[changeSetsDict removeObjectForKey:changeSet.uuid];
			}
			
		} while (changeSet != nil);
		
		// Check to see if there are more in the dictionary,
		// and keep going if needed.
		
		__block YDBCKChangeSet *remainingChangeSet = nil;
		[changeSetsDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
			
			remainingChangeSet = (YDBCKChangeSet *)obj;
			*stop = YES;
		}];
		
		changeSet = remainingChangeSet;
		offset = [orderedChangeSets count];
	}
	
	// Sanity check 1: Did we drain the changeSetsDict?
	
	if ([changeSetsDict count] != 0)
	{
		YDBLogError(@"Error restoring masterChangeQueue: Reverse-linked list corruption ! (A)");
		return NO;
	}
	
	// Sanity check 2: The changeSets are all in order
	
	NSString *prevUuid = [[orderedChangeSets firstObject] uuid];
	
	for (NSUInteger i = 1; i < [orderedChangeSets count]; i++)
	{
		YDBCKChangeSet *changeSet = [orderedChangeSets objectAtIndex:i];
		if (![changeSet.prev isEqualToString:prevUuid])
		{
			YDBLogError(@"Error restoring masterChangeQueue: Reverse-linked-list corruption ! (B)");
			return NO;
		}
		
		prevUuid = changeSet.uuid;
	}
	
	// Restore CKRecords as needed
	
	void (^RestoreRecordBlock)(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo);
	
	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithKeyBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithKeyBlock)parentConnection->parent->recordBlock;
		
		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
			
			YapCollectionKey *ck = [databaseTransaction collectionKeyForRowid:rowid];
			if (ck)
			{
				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key);
			}
		};
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithObjectBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithObjectBlock)parentConnection->parent->recordBlock;
		
		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
			
			YapCollectionKey *ck = nil;
			id object = nil;
			
			if ([databaseTransaction getCollectionKey:&ck object:&object forRowid:rowid])
			{
				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key, object);
			}
		};
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithMetadataBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithMetadataBlock)parentConnection->parent->recordBlock;
		
		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
			
			YapCollectionKey *ck = nil;
			id metadata = nil;
			
			if ([databaseTransaction getCollectionKey:&ck metadata:&metadata forRowid:rowid])
			{
				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key, metadata);
			}
		};
	}
	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
		
		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
			
			YapCollectionKey *ck = nil;
			id object = nil;
			id metadata = nil;
			
			if ([databaseTransaction getCollectionKey:&ck object:&object metadata:&metadata forRowid:rowid])
			{
				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key, object, metadata);
			}
		};
	}
	
	YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
	
	[orderedChangeSets enumerateObjectsUsingBlock:^(YDBCKChangeSet *changeSet, NSUInteger idx, BOOL *stop) {
		
		NSString *databaseIdentifier = changeSet.databaseIdentifier;
		
		recordInfo.databaseIdentifier = databaseIdentifier;
		[changeSet enumerateMissingRecordsWithBlock:
		    ^CKRecord *(CKRecordID *recordID, NSString *recordKeys_hash, NSArray *changedKeys)
		{
			NSString *hash = [self hashRecordID:recordID databaseIdentifier:databaseIdentifier];
			
			NSArray *rowids = [self mappingTableRowidsForRecordTableHash:hash];
			YDBCKCleanRecordTableInfo *cleanRecordTableInfo = [self recordTableInfoForHash:hash cacheResult:YES];
			
			__block CKRecord *record = [cleanRecordTableInfo.record safeCopy];
			
			NSMutableSet *unchangedKeys = [NSMutableSet setWithArray:[self keysForRecordKeysHash:recordKeys_hash]];
			for (NSString *key in changedKeys) {
				[unchangedKeys removeObject:key];
			}
			
			if (unchangedKeys.count > 0)
			{
				recordInfo.keysToRestore = [unchangedKeys allObjects];
				for (NSNumber *rowidNumber in rowids)
				{
					int64_t rowid = [rowidNumber longLongValue];
					RestoreRecordBlock(rowid, &record, recordInfo);
				}
			
				// You suck Apple.
				// Fix your friggin' CloudKit stack so we aren't forced to re-upload unchanged values!
			//	record = [YDBCKRecord recordWithClearedChangedKeys:record];
			}
			
			recordInfo.keysToRestore = changedKeys;
			for (NSNumber *rowidNumber in rowids)
			{
				int64_t rowid = [rowidNumber longLongValue];
				RestoreRecordBlock(rowid, &record, recordInfo);
			}
			
			return record;
		}];
	}];
	
	// Restore the changeSets (set them as the oldChangeSets in the masterQueue)
	
	[parentConnection->parent->masterQueue restoreOldChangeSets:orderedChangeSets];
	
	// Restart the uploads (if needed)
	
	BOOL forceNotification = NO;
	[parentConnection->parent asyncMaybeDispatchNextOperation:forceNotification];
	
	// Done!
	return YES;
}

- (BOOL)populateTables
{
	YDBLogAutoTrace();
	
	void (^InsertRecord)(NSString*, CKRecord*, int64_t rowid);
	InsertRecord = ^(NSString *databaseIdentifier, CKRecord *record, int64_t rowid) {
		
		NSString *hash = [self hashRecordID:record.recordID databaseIdentifier:databaseIdentifier];
		
		// Add row for mapping table
		
		YDBCKDirtyMappingTableInfo *dirtyMappingTableInfo;
		
		dirtyMappingTableInfo = [[YDBCKDirtyMappingTableInfo alloc] initWithRecordTableHash:nil];
		dirtyMappingTableInfo.dirty_recordTable_hash = hash;
		
		[parentConnection->cleanMappingTableInfoCache removeObjectForKey:@(rowid)];
		[parentConnection->dirtyMappingTableInfoDict setObject:dirtyMappingTableInfo forKey:@(rowid)];
		
		// Add/Update row for record table
		
		YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		  [parentConnection->dirtyRecordTableInfoDict objectForKey:hash];
		
		if (dirtyRecordTableInfo == nil)
		{
			dirtyRecordTableInfo =
			  [[YDBCKDirtyRecordTableInfo alloc] initWithDatabaseIdentifier:databaseIdentifier
			                                                       recordID:nil
			                                                     ownerCount:0
			                                                recordKeys_hash:nil];
			
			dirtyRecordTableInfo.dirty_ownerCount = 1;
			dirtyRecordTableInfo.dirty_record = record;
		
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:@(rowid)];
			[parentConnection->dirtyRecordTableInfoDict setObject:dirtyRecordTableInfo forKey:@(rowid)];
		}
		else
		{
			[self mergeChangedValuesFromRecord:record intoRecord:dirtyRecordTableInfo.dirty_record];
			
			[dirtyRecordTableInfo incrementOwnerCount];
		}
	};
	
	YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
	recordInfo.versionInfo = parentConnection->parent->versionInfo;
	
	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
	YapWhitelistBlacklist *allowedCollections = parentConnection->parent->options.allowedCollections;
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithKeyBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithKeyBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, BOOL *stop) {
			
			CKRecord *record = nil;
			recordInfo.databaseIdentifier = nil;
			
			recordBlock(&record, recordInfo, collection, key);
			
			if (record) {
				InsertRecord(recordInfo.databaseIdentifier, record, rowid);
			}
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateKeysInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateKeysInAllCollectionsUsingBlock:enumBlock];
		}
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithObjectBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithObjectBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, id object, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, id object, BOOL *stop) {
			
			CKRecord *record = nil;
			recordInfo.databaseIdentifier = nil;
			
			recordBlock(&record, recordInfo, collection, key, object);
			
			if (record) {
				InsertRecord(recordInfo.databaseIdentifier, record, rowid);
			}
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateKeysAndObjectsInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateKeysAndObjectsInAllCollectionsUsingBlock:enumBlock];
		}
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithMetadataBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithMetadataBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, id metadata, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, id metadata, BOOL *stop) {
			
			CKRecord *record = nil;
			recordInfo.databaseIdentifier = nil;
			
			recordBlock(&record, recordInfo, collection, key, metadata);
			
			if (record) {
				InsertRecord(recordInfo.databaseIdentifier, record, rowid);
			}
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateKeysAndMetadataInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateKeysAndMetadataInAllCollectionsUsingBlock:enumBlock];
		}
	}
	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, id object, id metadata, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, id object, id metadata, BOOL *stop) {
			
			CKRecord *record = nil;
			recordInfo.databaseIdentifier = nil;
			
			recordBlock(&record, recordInfo, collection, key, object, metadata);
			
			if (record) {
				InsertRecord(recordInfo.databaseIdentifier, record, rowid);
			}
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateRowsInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateRowsInAllCollectionsUsingBlock:enumBlock];
		}
	}
	
	return YES;
}

- (BOOL)repopulateTables
{
	YDBLogAutoTrace();
	
	YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
	recordInfo.versionInfo = parentConnection->parent->versionInfo;
	
	__block id <YDBCKMappingTableInfo> mappingTableInfo = nil;
	__block id <YDBCKRecordTableInfo> recordTableInfo = nil;
	__block CKRecord *record = nil;
	
	void (^enumHelperBlock)(int64_t) = ^(int64_t rowid)
	{
		mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:YES];
		recordTableInfo = [self recordTableInfoForHash:mappingTableInfo.current_recordTable_hash cacheResult:YES];
		
		recordInfo.databaseIdentifier = recordTableInfo.databaseIdentifier;
		
		if ([recordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
			  (YDBCKCleanRecordTableInfo *)recordInfo;
			
			record = [cleanRecordTableInfo.record safeCopy];
		}
		else if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
			  (YDBCKDirtyRecordTableInfo *)recordTableInfo;
			
			record = dirtyRecordTableInfo.dirty_record;
		}
		else
		{
			record = nil;
		}
	};
	
	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
	YapWhitelistBlacklist *allowedCollections = parentConnection->parent->options.allowedCollections;
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithKeyBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithKeyBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, BOOL *stop) {
			
			enumHelperBlock(rowid);
			recordBlock(&record, recordInfo, collection, key);
			
			[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
			                            preCalculatedHash:nil
			                                     forRowid:rowid
			                     withPrevMappingTableInfo:mappingTableInfo
			                          prevRecordTableInfo:recordTableInfo
			                                        flags:0];
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateKeysInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateKeysInAllCollectionsUsingBlock:enumBlock];
		}
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithObjectBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithObjectBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, id object, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, id object, BOOL *stop) {
			
			enumHelperBlock(rowid);
			recordBlock(&record, recordInfo, collection, key, object);
			
			[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
			                            preCalculatedHash:nil
			                                     forRowid:rowid
			                     withPrevMappingTableInfo:mappingTableInfo
			                          prevRecordTableInfo:recordTableInfo
			                                        flags:0];
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateKeysAndObjectsInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateKeysAndObjectsInAllCollectionsUsingBlock:enumBlock];
		}
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithMetadataBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithMetadataBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, id metadata, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, id metadata, BOOL *stop) {
			
			enumHelperBlock(rowid);
			recordBlock(&record, recordInfo, collection, key, metadata);
			
			[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
			                            preCalculatedHash:nil
			                                     forRowid:rowid
			                     withPrevMappingTableInfo:mappingTableInfo
			                          prevRecordTableInfo:recordTableInfo
			                                        flags:0];
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateKeysAndMetadataInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateKeysAndMetadataInAllCollectionsUsingBlock:enumBlock];
		}
	}
	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
		
		void (^enumBlock)(int64_t rowid, NSString *collection, NSString *key, id object, id metadata, BOOL *stop);
		enumBlock = ^(int64_t rowid, NSString *collection, NSString *key, id object, id metadata, BOOL *stop) {
			
			enumHelperBlock(rowid);
			recordBlock(&record, recordInfo, collection, key, object, metadata);
			
			[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
			                            preCalculatedHash:nil
			                                     forRowid:rowid
			                     withPrevMappingTableInfo:mappingTableInfo
			                          prevRecordTableInfo:recordTableInfo
			                                        flags:0];
		};
		
		if (allowedCollections)
		{
			[databaseTransaction enumerateCollectionsUsingBlock:^(NSString *collection, BOOL *stop) {
				
				if ([allowedCollections isAllowed:collection])
				{
					[databaseTransaction _enumerateRowsInCollections:@[ collection ] usingBlock:enumBlock];
				}
			}];
		}
		else
		{
			[databaseTransaction _enumerateRowsInAllCollectionsUsingBlock:enumBlock];
		}
	}
	
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Accessors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required override method from YapDatabaseExtensionTransaction.
**/
- (YapDatabaseReadTransaction *)databaseTransaction
{
	return databaseTransaction;
}

/**
 * Required override method from YapDatabaseExtensionTransaction.
**/
- (YapDatabaseExtensionConnection *)extensionConnection
{
	return parentConnection;
}

- (NSString *)registeredName
{
	return [parentConnection->parent registeredName];
}

- (NSString *)mappingTableName
{
	return [parentConnection->parent mappingTableName];
}

- (NSString *)recordTableName
{
	return [parentConnection->parent recordTableName];
}

- (NSString *)recordKeysTableName
{
	return [parentConnection->parent recordKeysTableName];
}

- (NSString *)queueTableName
{
	return [parentConnection->parent queueTableName];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities - General
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method hashes the given recordID & databaseIdentifier into a 160 bit hash,
 * and then returns a base64 representation of the hash.
**/
- (NSString *)hashRecordID:(CKRecordID *)recordID databaseIdentifier:(NSString *)databaseIdentifier
{
	// Edge case:
	//   Same recordID, but different databaseIdentifier.
	//   One is nil, the other is an empty string.
	//
	// We should try to make collisions nearly impossible
	// when using the same recordID across different databaseIdentifiers.
	
	NSString *rcd1 = recordID.recordName;
	NSString *rcd2 = recordID.zoneID.zoneName;
	NSString *rcd3 = recordID.zoneID.ownerName;
	
	__unsafe_unretained NSString *dbid = databaseIdentifier;
	
	if (rcd1 == nil) rcd1 = @"";
	if (rcd2 == nil) rcd2 = @"";
	if (rcd3 == nil) rcd3 = @"";
	// If dbid is nil, it stays nil
	
	NSUInteger maxLen = 2;
	
	maxLen = MAX(maxLen, [rcd1 lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
	maxLen = MAX(maxLen, [rcd2 lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
	maxLen = MAX(maxLen, [rcd3 lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
	maxLen = MAX(maxLen, [dbid lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
	
	int maxStackSize = 1024 * 2;
	
	uint8_t bufferStack[maxStackSize];
	void *buffer = NULL;
	
	if (maxLen <= maxStackSize)
		buffer = bufferStack;
	else
		buffer = malloc((size_t)maxLen);
	
	CC_SHA1_CTX ctx;
	CC_SHA1_Init(&ctx);
	
	NSUInteger used = 0;
	
	[rcd1 getBytes:buffer
	     maxLength:maxLen
	    usedLength:&used
	      encoding:NSUTF8StringEncoding
	       options:0
	         range:NSMakeRange(0, [rcd1 length]) remainingRange:NULL];
	
	CC_SHA1_Update(&ctx, buffer, (CC_LONG)used);
	
	[rcd2 getBytes:buffer
	     maxLength:maxLen
	    usedLength:&used
	      encoding:NSUTF8StringEncoding
	       options:0
	         range:NSMakeRange(0, [rcd2 length]) remainingRange:NULL];
	
	CC_SHA1_Update(&ctx, buffer, (CC_LONG)used);
	
	[rcd3 getBytes:buffer
	     maxLength:maxLen
	    usedLength:&used
	      encoding:NSUTF8StringEncoding
	       options:0
	         range:NSMakeRange(0, [rcd3 length]) remainingRange:NULL];
	
	CC_SHA1_Update(&ctx, buffer, (CC_LONG)used);
	
	if (dbid)
	{
		memcpy(buffer, (void *)'_', 1); // prefix with underscore to differentiate between nil & empty-string
		
		[dbid getBytes:(buffer + 1)
		     maxLength:(maxLen - 1)
		    usedLength:&used
		      encoding:NSUTF8StringEncoding
		       options:0
		         range:NSMakeRange(0, [dbid length]) remainingRange:NULL];
		
		CC_SHA1_Update(&ctx, buffer, (CC_LONG)(used + 1));
	}
	
	unsigned char hashBytes[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1_Final(hashBytes, &ctx);
	
	NSData *hashData = [NSData dataWithBytesNoCopy:(void *)hashBytes length:CC_SHA1_DIGEST_LENGTH freeWhenDone:NO];
	NSString *hashStr = [hashData base64EncodedStringWithOptions:0];
	
	if (maxLen > maxStackSize) {
		free(buffer);
	}
	return hashStr;
}

- (void)mergeChangedValuesFromRecord:(CKRecord *)fromRecord intoRecord:(CKRecord *)toRecord
{
	for (NSString *key in fromRecord.changedKeys)
	{
		id value = [fromRecord objectForKey:key];
		
		// The value may be nil.
		// This is ok, as it just means the modification was to remove the value.
		
		[toRecord setObject:value forKey:key];
	}
}

- (CKRecord *)baseRecordForCleanRecordTableInfo:(YDBCKCleanRecordTableInfo *)cleanRecordTableInfo
                                       withHash:(NSString *)hash
                           excludingChangedKeys:(NSArray *)changedKeys
{
//	void (^RestoreRecordBlock)(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo);
//	
//	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
//	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey)
//	{
//		__unsafe_unretained YapDatabaseCloudKitRecordWithKeyBlock recordBlock =
//		  (YapDatabaseCloudKitRecordWithKeyBlock)parentConnection->parent->recordBlock;
//		
//		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
//			
//			YapCollectionKey *ck = [databaseTransaction collectionKeyForRowid:rowid];
//			if (ck)
//			{
//				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key);
//			}
//		};
//	}
//	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithObject)
//	{
//		__unsafe_unretained YapDatabaseCloudKitRecordWithObjectBlock recordBlock =
//		  (YapDatabaseCloudKitRecordWithObjectBlock)parentConnection->parent->recordBlock;
//		
//		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
//			
//			YapCollectionKey *ck = nil;
//			id object = nil;
//			
//			if ([databaseTransaction getCollectionKey:&ck object:&object forRowid:rowid])
//			{
//				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key, object);
//			}
//		};
//	}
//	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata)
//	{
//		__unsafe_unretained YapDatabaseCloudKitRecordWithMetadataBlock recordBlock =
//		  (YapDatabaseCloudKitRecordWithMetadataBlock)parentConnection->parent->recordBlock;
//		
//		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
//			
//			YapCollectionKey *ck = nil;
//			id metadata = nil;
//			
//			if ([databaseTransaction getCollectionKey:&ck metadata:&metadata forRowid:rowid])
//			{
//				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key, metadata);
//			}
//		};
//	}
//	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
//	{
//		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
//		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
//		
//		RestoreRecordBlock = ^(int64_t rowid, CKRecord **inOutRecord, YDBCKRecordInfo *recordInfo) {
//			
//			YapCollectionKey *ck = nil;
//			id object = nil;
//			id metadata = nil;
//			
//			if ([databaseTransaction getCollectionKey:&ck object:&object metadata:&metadata forRowid:rowid])
//			{
//				recordBlock(inOutRecord, recordInfo, ck.collection, ck.key, object, metadata);
//			}
//		};
//	}
//	
//	NSArray *allKeys = [self keysForRecordKeysHash:cleanRecordTableInfo.recordKeys_hash];
//	
//	NSMutableSet *keysToRestore = [NSMutableSet setWithArray:allKeys];
//	for (NSString *key in changedKeys) {
//		[keysToRestore removeObject:key];
//	}
//	
//	__block CKRecord *baseRecord = [cleanRecordTableInfo.record safeCopy];
//	
//	if (keysToRestore.count > 0)
//	{
//		YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
//		recordInfo.keysToRestore = [keysToRestore allObjects];
//		
//		NSArray *rowids = [self mappingTableRowidsForRecordTableHash:hash];
//		for (NSNumber *rowidNumber in rowids)
//		{
//			int64_t rowid = [rowidNumber longLongValue];
//			RestoreRecordBlock(rowid, &baseRecord, recordInfo);
//		}
//		
//		// You suck Apple.
//		// Fix your friggin' CloudKit stack so we aren't forced to re-upload unchanged values!
//	//	baseRecord = [YDBCKRecord recordWithClearedChangedKeys:baseRecord];
//	}
//	
//	return baseRecord;
	
	return [cleanRecordTableInfo.record safeCopy];
}

- (void)processRecord:(CKRecord *)record databaseIdentifier:(NSString *)databaseIdentifier
                                          preCalculatedHash:(NSString *)preCalculatedRecordTableHash
                                                   forRowid:(int64_t)rowid
                                   withPrevMappingTableInfo:(id <YDBCKMappingTableInfo>)prevMappingTableInfo
                                        prevRecordTableInfo:(id <YDBCKRecordTableInfo>)prevRecordTableInfo
                                                      flags:(YDBCKProcessRecordBitMask)flags
{
	// Scenarios:
	//
	// - Rowid was not previously associated with record, and still is not.
	// - Rowid was not previously associated with record, but now it is.
	// - Rowid was previously associated with record, but now it is not.
	// - Rowid was previously associated with record, but is now associated with a different record.
	// - Rowid was previously associated with record, is still associated with same record, and made changes to record.
	
	NSString *prevRecordTableHash = prevMappingTableInfo.current_recordTable_hash;
	
	BOOL recordTableHashChangedForRowid = NO;
	NSString *newRecordTableHash = nil;
	
	if (prevRecordTableHash)
	{
		if (record)
		{
			// Is the rowid associated with a new/different {recordID, databaseIdentifier} tuple ?
			
			if (preCalculatedRecordTableHash)
				newRecordTableHash = preCalculatedRecordTableHash;
			else
				newRecordTableHash = [self hashRecordID:record.recordID databaseIdentifier:databaseIdentifier];
			
			if (![newRecordTableHash isEqualToString:prevRecordTableHash])
			{
				// Rowid is now associated with a different record.
				recordTableHashChangedForRowid = YES;
			}
		}
		else
		{
			// Rowid is no longer associated with a record.
			recordTableHashChangedForRowid = YES;
		}
	}
	else if (record)
	{
		// Rowid is now associated with a record. (previously was not)
		
		if (preCalculatedRecordTableHash)
			newRecordTableHash = preCalculatedRecordTableHash;
		else
			newRecordTableHash = [self hashRecordID:record.recordID databaseIdentifier:databaseIdentifier];
		
		recordTableHashChangedForRowid = YES;
	}
	
	// ORDER MATTERS:
	//
	// If there is an existing cleanRecordTableInfo for this record,
	// then we'll be forced to restore a baseRecord via baseRecordForCleanRecordTableInfo:::.
	// And this method enumerates the mappings in order to restore the baseRecord.
	//
	// Thus:
	//
	// if (recordTableHashChangedForRowid && newRecordTableHash)
	// {
	//     // Rowid is associated with new record.
	//     ...
	//
	// ->  Do this BEFORE updating the mappings
	// }
	//
	// if (recordTableHashChangedForRowid && prevRecordTableInfo)
	// {
	//     // Rowid is no longer associated with record.
	//     ...
	//
	// ->  Do this AFTER updating the mappings
	// }
	
	if (recordTableHashChangedForRowid && newRecordTableHash)
	{
		// Rowid is associated with new record.
		// Need to either create new entry in record table,
		// or increment ownerCount of existing entry in record table (and merge any record changes).
		
		id newRecordTableInfo = [self recordTableInfoForHash:newRecordTableHash cacheResult:NO];
		
		BOOL recordHasChangedValues = ([record.changedKeys count] > 0);
		
		BOOL remoteMerge = (flags & YDBCK_remoteMerge) ? YES : NO;
		BOOL skipUploadRecord = (flags & YDBCK_skipUploadRecord) ? YES : NO;
		
		if ([newRecordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKDirtyRecordTableInfo *newDirtyRecordTableInfo =
			  (YDBCKDirtyRecordTableInfo *)newRecordTableInfo;
			
			[self mergeChangedValuesFromRecord:record intoRecord:newDirtyRecordTableInfo.dirty_record];
			[newDirtyRecordTableInfo incrementOwnerCount];
			
			if (remoteMerge) newDirtyRecordTableInfo.remoteMerge = YES;
			
			if (newDirtyRecordTableInfo.skipUploadRecord && recordHasChangedValues && !skipUploadRecord) {
				newDirtyRecordTableInfo.skipUploadRecord = NO;
			}
		}
		else if ([newRecordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKCleanRecordTableInfo *newCleanRecordTableInfo =
			  (YDBCKCleanRecordTableInfo *)newRecordTableInfo;
			
			CKRecord *baseRecord = [self baseRecordForCleanRecordTableInfo:newCleanRecordTableInfo
			                                                      withHash:newRecordTableHash
			                                          excludingChangedKeys:record.changedKeys];
			
			YDBCKDirtyRecordTableInfo *newDirtyRecordTableInfo =
			  [newCleanRecordTableInfo dirtyCopyWithBaseRecord:baseRecord];
			
			[self mergeChangedValuesFromRecord:record intoRecord:newDirtyRecordTableInfo.dirty_record];
			[newDirtyRecordTableInfo incrementOwnerCount];
			
			if (remoteMerge) newDirtyRecordTableInfo.remoteMerge = YES;
			if (skipUploadRecord) newDirtyRecordTableInfo.skipUploadRecord = YES;
			
			if (!recordHasChangedValues) { // association only
				newDirtyRecordTableInfo.skipUploadRecord = YES;
			}
			
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:newRecordTableHash];
			[parentConnection->dirtyRecordTableInfoDict setObject:newDirtyRecordTableInfo forKey:newRecordTableHash];
		}
		else
		{
			YDBCKDirtyRecordTableInfo *newDirtyRecordTableInfo =
			  [[YDBCKDirtyRecordTableInfo alloc] initWithDatabaseIdentifier:databaseIdentifier
			                                                       recordID:nil
			                                                     ownerCount:0
			                                                recordKeys_hash:nil];
			
			newDirtyRecordTableInfo.dirty_ownerCount = 1;
			newDirtyRecordTableInfo.dirty_record = record;
			
			if (remoteMerge) newDirtyRecordTableInfo.remoteMerge = YES;
			if (skipUploadRecord) newDirtyRecordTableInfo.skipUploadRecord = YES;
			
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:newRecordTableHash];
			[parentConnection->dirtyRecordTableInfoDict setObject:newDirtyRecordTableInfo forKey:newRecordTableHash];
		}
	}
	
	if (recordTableHashChangedForRowid)
	{
		// Update mapping
		
		if ([prevMappingTableInfo isKindOfClass:[YDBCKDirtyMappingTableInfo class]])
		{
			__unsafe_unretained YDBCKDirtyMappingTableInfo *dirtyMappingTableInfo =
			  (YDBCKDirtyMappingTableInfo *)prevMappingTableInfo;
			
			dirtyMappingTableInfo.dirty_recordTable_hash = newRecordTableHash;
		}
		else
		{
			YDBCKDirtyMappingTableInfo *dirtyMappingTableInfo;
			
			dirtyMappingTableInfo = [[YDBCKDirtyMappingTableInfo alloc] initWithRecordTableHash:prevRecordTableHash];
			dirtyMappingTableInfo.dirty_recordTable_hash = newRecordTableHash;
			
			[parentConnection->cleanMappingTableInfoCache removeObjectForKey:@(rowid)];
			[parentConnection->dirtyMappingTableInfoDict setObject:dirtyMappingTableInfo forKey:@(rowid)];
		}
	}
	
	if (recordTableHashChangedForRowid && prevRecordTableInfo)
	{
		// Rowid is no longer associated with record.
		// Need to decrement ownerCount.
		// If ownerCount drops to zero, then the record will be removed during commit processing.
		
		BOOL remoteDeletion = (flags & YDBCK_remoteDeletion) ? YES : NO;
		BOOL skipUploadDeletion = (flags & YDBCK_skipUploadDeletion) ? YES : NO;
		
		if ([prevRecordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
			  (YDBCKDirtyRecordTableInfo *)prevRecordTableInfo;
			
			[dirtyRecordTableInfo decrementOwnerCount];
			
			if (remoteDeletion)     dirtyRecordTableInfo.remoteDeletion = remoteDeletion;
			if (skipUploadDeletion) dirtyRecordTableInfo.skipUploadDeletion = skipUploadDeletion;
		}
		else
		{
			__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
			  (YDBCKCleanRecordTableInfo *)prevRecordTableInfo;
			
			CKRecord *baseRecord = [self baseRecordForCleanRecordTableInfo:cleanRecordTableInfo
			                                                      withHash:prevRecordTableHash
			                                          excludingChangedKeys:nil];
			
			YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = [cleanRecordTableInfo dirtyCopyWithBaseRecord:baseRecord];
			[dirtyRecordTableInfo decrementOwnerCount];
			
			if (remoteDeletion)     dirtyRecordTableInfo.remoteDeletion = remoteDeletion;
			if (skipUploadDeletion) dirtyRecordTableInfo.skipUploadDeletion = skipUploadDeletion;
			
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:prevRecordTableHash];
			[parentConnection->dirtyRecordTableInfoDict setObject:dirtyRecordTableInfo forKey:prevRecordTableHash];
		}
	}
	
	if (!recordTableHashChangedForRowid && ([record.changedKeys count] > 0))
	{
		if ([prevRecordTableInfo isKindOfClass:[YDBCKDirtyMappingTableInfo class]])
		{
			__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
			  (YDBCKDirtyRecordTableInfo *)prevRecordTableInfo;
			
			[self mergeChangedValuesFromRecord:record intoRecord:dirtyRecordTableInfo.dirty_record];
		}
		else if ([prevRecordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
			  (YDBCKCleanRecordTableInfo *)prevRecordTableInfo;
			
			CKRecord *baseRecord = [self baseRecordForCleanRecordTableInfo:cleanRecordTableInfo
			                                                      withHash:prevRecordTableHash
			                                          excludingChangedKeys:record.changedKeys];
			
			YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = [cleanRecordTableInfo dirtyCopyWithBaseRecord:baseRecord];
			
			[self mergeChangedValuesFromRecord:record intoRecord:dirtyRecordTableInfo.dirty_record];
			
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:newRecordTableHash];
			[parentConnection->dirtyRecordTableInfoDict setObject:dirtyRecordTableInfo forKey:newRecordTableHash];
		}
		else
		{
			YDBCKDirtyRecordTableInfo *newDirtyRecordTableInfo =
			  [[YDBCKDirtyRecordTableInfo alloc] initWithDatabaseIdentifier:databaseIdentifier
			                                                       recordID:nil
			                                                     ownerCount:0
			                                                recordKeys_hash:nil];
			
			newDirtyRecordTableInfo.dirty_ownerCount = 1;
			newDirtyRecordTableInfo.dirty_record = record;
			
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:newRecordTableHash];
			[parentConnection->dirtyRecordTableInfoDict setObject:newDirtyRecordTableInfo forKey:newRecordTableHash];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities - MappingTable
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (id <YDBCKMappingTableInfo>)mappingTableInfoForRowid:(int64_t)rowid cacheResult:(BOOL)cacheResult
{
	YDBLogAutoTrace();
	
	NSNumber *rowidNumber = @(rowid);
	YDBCKDirtyMappingTableInfo *dirtyMappingTableInfo = nil;
	YDBCKCleanMappingTableInfo *cleanMappingTableInfo = nil;
	
	// Check dirtyMappingTableInfo (modified info)
	
	dirtyMappingTableInfo = [parentConnection->dirtyMappingTableInfoDict objectForKey:rowidNumber];
	if (dirtyMappingTableInfo) {
		return dirtyMappingTableInfo;
	}
	
	// Check cleanMappingTableInfo (cache)
	
	cleanMappingTableInfo = [parentConnection->cleanMappingTableInfoCache objectForKey:rowidNumber];
	if (cleanMappingTableInfo)
	{
		if (cleanMappingTableInfo == (id)[NSNull null])
			return nil;
		else
			return cleanMappingTableInfo;
	}
	
	// Fetch from disk
	
	sqlite3_stmt *statement = [parentConnection mappingTable_getInfoForRowidStatement];
	if (statement == NULL) {
		return nil;
	}
	
	// SELECT "recordTable_hash" FROM "mappingTableName" WHERE "rowid" = ?;
	
	int col_recordTable_hash = SQLITE_COL_START + 0;
	int bind_rowid = SQLITE_BIND_START + 0;
	
	sqlite3_bind_int64(statement, bind_rowid, rowid);
	
	NSString *recordTable_hash = nil;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		int textSize = sqlite3_column_bytes(statement, col_recordTable_hash);
		if (textSize > 0)
		{
			const unsigned char *text = sqlite3_column_text(statement, col_recordTable_hash);
			
			recordTable_hash = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		}
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'mappingTable_getInfoForRowidStatement': %d %s",
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	
	if (recordTable_hash)
	{
		cleanMappingTableInfo = [[YDBCKCleanMappingTableInfo alloc] initWithRecordTableHash:recordTable_hash];
		
		if (cacheResult){
			[parentConnection->cleanMappingTableInfoCache setObject:cleanMappingTableInfo forKey:rowidNumber];
		}
		return cleanMappingTableInfo;
	}
	else
	{
		if (cacheResult) {
			[parentConnection->cleanMappingTableInfoCache setObject:[NSNull null] forKey:rowidNumber];
		}
		return nil;
	}
}

/**
 * This method is called from handleRemoveObjectsForKeys:inCollection:withRowids:.
 *
 * It's used to fetch all the mappingTableInfo items for all the given rowids.
 * This information is used in order to determine which rowids are mapped to a CKRecords (in the record table).
**/
- (NSDictionary *)mappingTableInfoForRowids:(NSArray *)rowids
{
	YDBLogAutoTrace();
	
	NSUInteger rowidsCount = rowids.count;
	
	if (rowidsCount == 0) return nil;
	if (rowidsCount == 1) {
		
		int64_t rowid = [[rowids firstObject] longLongValue];
		id <YDBCKMappingTableInfo> mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:NO];
		
		if (mappingTableInfo)
			return @{ @(rowid) : mappingTableInfo };
		else
			return nil;
	}
	
	NSMutableDictionary *foundRowids = [NSMutableDictionary dictionaryWithCapacity:rowidsCount];
	NSMutableArray *remainingRowids = [NSMutableArray arrayWithCapacity:rowidsCount];
	
	for (NSNumber *rowidNumber in rowids)
	{
		YDBCKDirtyMappingTableInfo *dirtyMappingTableInfo = nil;
		YDBCKCleanMappingTableInfo *cleanMappingTableInfo = nil;
		
		// Check dirtyMappingTableInfo (modified info)
		
		dirtyMappingTableInfo = [parentConnection->dirtyMappingTableInfoDict objectForKey:rowidNumber];
		if (dirtyMappingTableInfo)
		{
			[foundRowids setObject:dirtyMappingTableInfo forKey:rowidNumber];
			continue;
		}
		
		// Check cleanMappingTableInfo (cache)
		
		cleanMappingTableInfo = [parentConnection->cleanMappingTableInfoCache objectForKey:rowidNumber];
		if (cleanMappingTableInfo)
		{
			if (cleanMappingTableInfo != (id)[NSNull null])
			{
				[foundRowids setObject:cleanMappingTableInfo forKey:rowidNumber];
			}
			
			continue;
		}
		
		// Need to fetch from disk
		
		[remainingRowids addObject:rowidNumber];
	}
	
	NSUInteger count = [remainingRowids count];
	if (count > 0)
	{
		sqlite3 *db = databaseTransaction->connection->db;
		
		// Note:
		// The handleRemoveObjectsForKeys:inCollection:withRowids: has the following guarantee:
		//     count <= (SQLITE_LIMIT_VARIABLE_NUMBER - 1)
		//
		// So we don't have to worry about sqlite's upper bound on host parameters.
		
		// SELECT "recordTable_hash" FROM "mappingTableName" WHERE "rowid" IN (?, ?, ...);
		
		NSUInteger capacity = 100 + (count * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendString:@"SELECT \"rowid\", \"recordTable_hash\""];
		[query appendFormat:@" FROM \"%@\" WHERE \"rowid\" IN (", [self mappingTableName]];
		
		int col_rowid            = SQLITE_COL_START + 0;
		int col_recordTable_hash = SQLITE_COL_START + 1;
		
		for (NSUInteger i = 0; i < count; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		int status;
		
		status = sqlite3_prepare_v2(db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@ (%@): Error creating statement\n"
			            @" - status(%d), errmsg: %s\n"
			            @" - query: %@",
			            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db), query);
			
			return foundRowids;
		}
		
		for (NSUInteger i = 0; i < count; i++)
		{
			int64_t rowid = [[remainingRowids objectAtIndex:i] longLongValue];
			
			sqlite3_bind_int64(statement, (int)(SQLITE_BIND_START + i), rowid);
		}
		
		while ((status = sqlite3_step(statement)) == SQLITE_ROW)
		{
			int64_t rowid = 0;
			NSString *recordTable_hash = nil;
			
			rowid = sqlite3_column_int64(statement, col_rowid);
			
			int textLen = sqlite3_column_bytes(statement, col_recordTable_hash);
			const unsigned char *text = sqlite3_column_text(statement, col_recordTable_hash);
			
			recordTable_hash = [[NSString alloc] initWithBytes:text length:textLen encoding:NSUTF8StringEncoding];
			
			if (recordTable_hash)
			{
				YDBCKCleanMappingTableInfo *cleanMappingTableInfo =
				  [[YDBCKCleanMappingTableInfo alloc] initWithRecordTableHash:recordTable_hash];
				
				[foundRowids setObject:cleanMappingTableInfo forKey:@(rowid)];
			}
		}
		
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ (%@): Error executing statement: %d %s",
						THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
		}
		
		sqlite3_finalize(statement);
	}
	
	return foundRowids;
}

- (void)insertOrUpdateMappingTableRowWithRowid:(int64_t)rowid info:(YDBCKDirtyMappingTableInfo *)dirtyMappingTableInfo
{
	if (dirtyMappingTableInfo.clean_recordTable_hash == nil)
	{
		// Insert row
		
		NSAssert(dirtyMappingTableInfo.dirty_recordTable_hash != nil, @"Logic error");
		
		sqlite3_stmt *statement = [parentConnection mappingTable_insertStatement];
		if (statement == NULL) {
			return;
		}
		
		// INSERT OR REPLACE INTO "mappingTableName" ("rowid", "recordTable_hash") VALUES (?, ?);
		
		int bind_rowid            = SQLITE_BIND_START + 0;
		int bind_recordTable_hash = SQLITE_BIND_START + 1;
		
		sqlite3_bind_int64(statement, bind_rowid, rowid);
		
		YapDatabaseString _hash; MakeYapDatabaseString(&_hash, dirtyMappingTableInfo.dirty_recordTable_hash);
		sqlite3_bind_text(statement, bind_recordTable_hash, _hash.str, _hash.length, SQLITE_STATIC);
		
		YDBLogVerbose(@"Inserting 1 row in mapping table with rowid(%lld)...", rowid);
		
		int status = sqlite3_step(statement);
		if (status == SQLITE_ERROR)
		{
			YDBLogError(@"%@ - Error executing statement (insert): %d %s", THIS_METHOD,
						status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_hash);
		
	}
	else
	{
		// Update row
		
		NSAssert(dirtyMappingTableInfo.dirty_recordTable_hash != nil, @"Logic error");
		
		sqlite3_stmt *statement = [parentConnection mappingTable_updateForRowidStatement];
		if (statement == NULL) {
			return;
		}
		
		// UPDATE "mappingTableName" SET "recordTable_hash" = ? WHERE "rowid" = ?;
		
		int bind_recordTable_hash = SQLITE_BIND_START + 0;
		int bind_rowid            = SQLITE_BIND_START + 1;
		
		YapDatabaseString _hash; MakeYapDatabaseString(&_hash, dirtyMappingTableInfo.dirty_recordTable_hash);
		sqlite3_bind_text(statement, bind_recordTable_hash, _hash.str, _hash.length, SQLITE_STATIC);
		
		sqlite3_bind_int64(statement, bind_rowid, rowid);
		
		YDBLogVerbose(@"Updating 1 row in mapping table with rowid(%lld)...", rowid);
		
		int status = sqlite3_step(statement);
		if (status == SQLITE_ERROR)
		{
			YDBLogError(@"%@ - Error executing statement (insert): %d %s", THIS_METHOD,
						status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_hash);
	}
}

- (void)removeMappingTableRowWithRowid:(int64_t)rowid
{
	sqlite3_stmt *statement = [parentConnection mappingTable_removeForRowidStatement];
	if (statement == NULL) {
		return;
	}
	
	// DELETE FROM "mappingTableName" WHERE "rowid" = ?;
	
	int bind_rowid = SQLITE_BIND_START + 0;
	
	sqlite3_bind_int64(statement, bind_rowid, rowid);
	
	YDBLogVerbose(@"Deleting 1 row from mapping table with rowid(%lld)...", rowid);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@ - Error executing statement (remove): %d %s", THIS_METHOD,
					status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
}

- (void)removeAllMappingTableRows
{
	YDBLogAutoTrace();
	
	sqlite3_stmt *statement = [parentConnection mappingTable_removeAllStatement];
	if (statement == NULL) {
		return;
	}
	
	// DELETE FROM "mappingTableName";
	
	YDBLogVerbose(@"Deleting all rows from mapping table...");
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_reset(statement);
}

/**
 * Uses the index on the 'recordTable_hash' column to find associated rowids.
 * And also takes into account pending changes to the mapping table via dirtyMappingTableInfoDict.
**/
- (NSArray *)mappingTableRowidsForRecordTableHash:(NSString *)hash
{
	sqlite3_stmt *statement = [parentConnection mappingTable_enumerateForHashStatement];
	if (statement == NULL) {
		return nil;
	}
	
	NSMutableSet *rowids = [NSMutableSet set];
	
	// SELECT "rowid" FROM "mappingTableName" WHERE "recordTable_hash" = ?;
	
	int col_rowid = SQLITE_COL_START + 0;
	int bind_hash = SQLITE_BIND_START + 0;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	int status;
	while ((status = sqlite3_step(statement)) == SQLITE_ROW)
	{
		int64_t rowid = sqlite3_column_int64(statement, col_rowid);
		
		[rowids addObject:@(rowid)];
	}
	
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"Error executing 'getKeyCountForCollectionStatement': %d %s",
					status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
	
	[parentConnection->dirtyMappingTableInfoDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		__unsafe_unretained NSNumber *rowidNumber = (NSNumber *)key;
		__unsafe_unretained YDBCKDirtyMappingTableInfo *dirtyMappingTableInfo = (YDBCKDirtyMappingTableInfo *)obj;
		
		if ([hash isEqualToString:dirtyMappingTableInfo.clean_recordTable_hash])
		{
			if (![hash isEqualToString:dirtyMappingTableInfo.dirty_recordTable_hash])
			{
				// Mapping is scheduled to be removed
				[rowids removeObject:rowidNumber];
			}
		}
		else if ([hash isEqualToString:dirtyMappingTableInfo.dirty_recordTable_hash])
		{
			// Mapping is scheduled to be added
			[rowids addObject:rowidNumber];
		}
	}];
	
	return [rowids allObjects];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities - RecordTable
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method returns one of the following instance types:
 *
 * - YDBCKCleanRecordTableInfo
 * - YDBCKDirtyRecordTableInfo
 * - nil
 *
 * The caller must inspect the class type of the returned object.
**/
- (id <YDBCKRecordTableInfo>)recordTableInfoForHash:(NSString *)hash cacheResult:(BOOL)cacheResult
{
	YDBLogAutoTrace();
	
	if (hash == nil) return nil;
	
	YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = nil;
	YDBCKCleanRecordTableInfo *cleanRecordTableInfo = nil;
	
	// Check dirtyRecordTableInfo (modified records)
	
	dirtyRecordTableInfo = [parentConnection->dirtyRecordTableInfoDict objectForKey:hash];
	if (dirtyRecordTableInfo) {
		return dirtyRecordTableInfo;
	}
	
	// Check cleanRecordTableInfo (cache)
	
	cleanRecordTableInfo = [parentConnection->cleanRecordTableInfoCache objectForKey:hash];
	if (cleanRecordTableInfo)
	{
		if (cleanRecordTableInfo == (id)[NSNull null])
			return nil;
		else
			return cleanRecordTableInfo;
	}
	
	// Fetch from disk
	
	sqlite3_stmt *statement = [parentConnection recordTable_getInfoForHashStatement];
	if (statement == NULL) {
		return nil;
	}
	
	// SELECT "databaseIdentifier", "ownerCount", "recordKeys_hash", "record" FROM "recordTableName" WHERE "hash" = ?;
	
	int col_databaseIdentifier = SQLITE_COL_START + 0;
	int col_ownerCount         = SQLITE_COL_START + 1;
	int col_recordKeys_hash    = SQLITE_COL_START + 2;
	int col_record             = SQLITE_COL_START + 3;
	
	int bind_hash = SQLITE_BIND_START + 0;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	NSString *databaseIdentifier = nil;
	int64_t ownerCount = 0;
	NSString *recordKeys_hash = nil;
	CKRecord *record = nil;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		int textSize;
		
		textSize = sqlite3_column_bytes(statement, col_databaseIdentifier);
		if (textSize > 0)
		{
			const unsigned char *text = sqlite3_column_text(statement, col_databaseIdentifier);
			databaseIdentifier = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		}
		
		ownerCount = sqlite3_column_int64(statement, col_ownerCount);
		
		textSize = sqlite3_column_bytes(statement, col_recordKeys_hash);
		if (textSize > 0)
		{
			const unsigned char *text = sqlite3_column_text(statement, col_recordKeys_hash);
			recordKeys_hash = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		}
		
		const void *blob = sqlite3_column_blob(statement, col_record);
		int blobSize = sqlite3_column_bytes(statement, col_record);
		
		// Performance tuning:
		// Use dataWithBytesNoCopy to avoid an extra allocation and memcpy.
		
		NSData *data = [NSData dataWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
		
		record = [YDBCKRecord deserializeRecord:data];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'recordTable_getInfoForHashStatement': %d %s",
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
	
	if (record)
	{
		cleanRecordTableInfo =
		  [[YDBCKCleanRecordTableInfo alloc] initWithDatabaseIdentifier:databaseIdentifier
		                                                     ownerCount:ownerCount
		                                                recordKeys_hash:recordKeys_hash
		                                                         record:record];
		
		if (cacheResult){
			[parentConnection->cleanRecordTableInfoCache setObject:cleanRecordTableInfo forKey:hash];
		}
		return cleanRecordTableInfo;
	}
	else
	{
		if (cacheResult) {
			[parentConnection->cleanRecordTableInfoCache setObject:[NSNull null] forKey:hash];
		}
		return nil;
	}
}

/**
 * This method is called from handleRemoveObjectsForKeys:inCollection:withRowids:.
 * 
 * It's used to fetch all the recordInfo items for all the given rowids.
 * This information is used in order to determine which rowids have associated CKRecords,
 * and should be deleted (locally and possibly from the cloud too).
**/
- (NSDictionary *)recordTableInfoForHashes:(NSArray *)hashes
{
	NSUInteger hashesCount = hashes.count;
	
	if (hashesCount == 0) return nil;
	if (hashesCount == 1) {
		
		NSString *hash = [hashes firstObject];
		id <YDBCKRecordTableInfo> recordTableInfo = [self recordTableInfoForHash:hash cacheResult:NO];
		
		if (recordTableInfo)
			return @{ hash : recordTableInfo };
		else
			return nil;
	}
	
	NSMutableDictionary *foundHashes = [NSMutableDictionary dictionaryWithCapacity:[hashes count]];
	NSMutableArray *remainingHashes = [NSMutableArray arrayWithCapacity:[hashes count]];
	
	for (NSString *hash in hashes)
	{
		YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = nil;
		YDBCKCleanRecordTableInfo *cleanRecordTableInfo = nil;
		
		// Check dirtyRecordTableInfo (modified records)
		
		dirtyRecordTableInfo = [parentConnection->dirtyRecordTableInfoDict objectForKey:hash];
		if (dirtyRecordTableInfo)
		{
			[foundHashes setObject:dirtyRecordTableInfo forKey:hash];
			continue;
		}
		
		// Check cleanRecordTableInfo (cache)
		
		cleanRecordTableInfo = [parentConnection->cleanRecordTableInfoCache objectForKey:hash];
		if (cleanRecordTableInfo)
		{
			if (cleanRecordTableInfo != (id)[NSNull null])
			{
				[foundHashes setObject:cleanRecordTableInfo forKey:hash];
			}
			
			continue;
		}
		
		// Need to fetch from disk
		
		[remainingHashes addObject:hash];
	}
	
	NSUInteger count = [remainingHashes count];
	if (count > 0)
	{
		sqlite3 *db = databaseTransaction->connection->db;
		
		// Note:
		// The handleRemoveObjectsForKeys:inCollection:withRowids: has the following guarantee:
		//     count <= (SQLITE_LIMIT_VARIABLE_NUMBER - 1)
		//
		// So we don't have to worry about sqlite's upper bound on host parameters.
		
		// SELECT "hash", "databaseIdentifier", "ownerCount", "record" FROM "recordTableName"
		//  WHERE "hash" IN (?, ?, ...);
		
		NSUInteger capacity = 100 + (count * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendString:
		  @"SELECT \"hash\", \"databaseIdentifier\", \"ownerCount\", \"recordKeys_hash\", \"record\""];
		[query appendFormat:@" FROM \"%@\" WHERE \"hash\" IN (", [self recordTableName]];
		
		int col_hash               = SQLITE_COL_START + 0;
		int col_databaseIdentifier = SQLITE_COL_START + 1;
		int col_ownerCount         = SQLITE_COL_START + 2;
		int col_recordKeys_hash    = SQLITE_COL_START + 3;
		int col_record             = SQLITE_COL_START + 4;
		
		for (NSUInteger i = 0; i < count; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		int status;
		
		status = sqlite3_prepare_v2(db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@ (%@): Error creating statement\n"
			            @" - status(%d), errmsg: %s\n"
			            @" - query: %@",
			            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db), query);
			
			return foundHashes;
		}
		
		for (NSUInteger i = 0; i < count; i++)
		{
			NSString *hash = [remainingHashes objectAtIndex:i];
			
			sqlite3_bind_text(statement, (int)(SQLITE_BIND_START + i), [hash UTF8String], -1, SQLITE_TRANSIENT);
		}
		
		while ((status = sqlite3_step(statement)) == SQLITE_ROW)
		{
			NSString *hash = nil;
			NSString *databaseIdentifier = nil;
			int64_t ownerCount = 0;
			NSString *recordKeys_hash = nil;
			CKRecord *record = nil;
			
			int textLen;
			const unsigned char *text;
			
			textLen = sqlite3_column_bytes(statement, col_hash);
			text = sqlite3_column_text(statement, col_hash);
			
			hash = [[NSString alloc] initWithBytes:text length:textLen encoding:NSUTF8StringEncoding];
			
			textLen = sqlite3_column_bytes(statement, col_databaseIdentifier);
			if (textLen > 0)
			{
				text = sqlite3_column_text(statement, col_databaseIdentifier);
				databaseIdentifier = [[NSString alloc] initWithBytes:text length:textLen encoding:NSUTF8StringEncoding];
			}
			
			ownerCount = sqlite3_column_int64(statement, col_ownerCount);
			
			textLen = sqlite3_column_bytes(statement, col_recordKeys_hash);
			if (textLen > 0)
			{
				text = sqlite3_column_text(statement, col_recordKeys_hash);
				recordKeys_hash = [[NSString alloc] initWithBytes:text length:textLen encoding:NSUTF8StringEncoding];
			}
			
			const void *blob = sqlite3_column_blob(statement, col_record);
			int blobSize = sqlite3_column_bytes(statement, col_record);
			
			// Performance tuning:
			// Use dataWithBytesNoCopy to avoid an extra allocation and memcpy.
			
			NSData *data = [NSData dataWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
			record = [YDBCKRecord deserializeRecord:data];
			
			if (record)
			{
				YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
				  [[YDBCKCleanRecordTableInfo alloc] initWithDatabaseIdentifier:databaseIdentifier
				                                                     ownerCount:ownerCount
				                                                recordKeys_hash:recordKeys_hash
				                                                         record:record];
				
				[foundHashes setObject:cleanRecordTableInfo forKey:hash];
			}
		}
		
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ (%@): Error executing statement: %d %s",
						THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
		}
		
		sqlite3_finalize(statement);
	}
	
	return foundHashes;
}

/**
 * Inserts the given dirtyRecordTableInfo into the recordTable.
 *
 * Returns a corresponding row that needs to be inserted into the recordKeysTable.
 * The caller is responsible for inserting the recordKeysRow.
**/
- (YDBCKRecordKeysRow *)insertRecordTableRowWithHash:(NSString *)hash
                                                info:(YDBCKDirtyRecordTableInfo *)dirtyRecordTableInfo
                                  outSanitizedRecord:(CKRecord **)outSanitizedRecord
{
	YDBLogAutoTrace();
	
	NSParameterAssert(hash != nil);
	NSParameterAssert(dirtyRecordTableInfo != nil);
	
	NSAssert(dirtyRecordTableInfo.dirty_record != nil, @"Logic error");
	NSAssert(dirtyRecordTableInfo.dirty_ownerCount > 0, @"Logic error");
	
	YDBCKRecordKeysRow *recordKeysRow = [YDBCKRecordKeysRow hashRecordKeys:dirtyRecordTableInfo.dirty_record];
	
	// Update recordKeys table
	
	sqlite3_stmt *statement = [parentConnection recordTable_insertStatement];
	if (statement == NULL)
	{
		if (outSanitizedRecord) *outSanitizedRecord = nil;
		return recordKeysRow;
	}
	
	// INSERT OR REPLACE INTO "recordTableName"
	//   ("hash", "databaseIdentifier", "ownerCount", "recordKeys_hash", "record") VALUES (?, ?, ?, ?, ?);
	
	int bind_hash               = SQLITE_BIND_START + 0;
	int bind_databaseIdentifier = SQLITE_BIND_START + 1;
	int bind_ownerCount         = SQLITE_BIND_START + 2;
	int bind_recordKeys_hash    = SQLITE_BIND_START + 3;
	int bind_record             = SQLITE_BIND_START + 4;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	YapDatabaseString _dbID; MakeYapDatabaseString(&_dbID, dirtyRecordTableInfo.databaseIdentifier);
	if (dirtyRecordTableInfo.databaseIdentifier)
		sqlite3_bind_text(statement, bind_databaseIdentifier, _dbID.str, _dbID.length, SQLITE_STATIC);
	else
		sqlite3_bind_null(statement, bind_databaseIdentifier);
	
	sqlite3_bind_int64(statement, bind_ownerCount, dirtyRecordTableInfo.dirty_ownerCount);
	
	YapDatabaseString _recordKeys_hash; MakeYapDatabaseString(&_recordKeys_hash, recordKeysRow.hash);
	sqlite3_bind_text(statement, bind_recordKeys_hash, _recordKeys_hash.str, _recordKeys_hash.length, SQLITE_STATIC);
	
	__attribute__((objc_precise_lifetime)) NSData *recordBlob =
	  [YDBCKRecord serializeRecord:dirtyRecordTableInfo.dirty_record];
	sqlite3_bind_blob(statement, bind_record, recordBlob.bytes, (int)recordBlob.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
	FreeYapDatabaseString(&_dbID);
	FreeYapDatabaseString(&_recordKeys_hash);
	
	if (outSanitizedRecord) {
		CKRecord *sanitizedRecord = [YDBCKRecord deserializeRecord:recordBlob];
		*outSanitizedRecord = sanitizedRecord;
	}
	return recordKeysRow;
}

/**
 * Updates the metadata columns (ownerCount, recordKeys_hash) for the record IF NEEDED.
 * 
 * Returns a corresponding row that needs to be inserted into the recordKeysTable.
 * The caller is responsible for inserting the recordKeysRow.
**/
- (YDBCKRecordKeysRow *)maybeUpdateRecordTableRowWithHash:(NSString *)hash
                                                     info:(YDBCKDirtyRecordTableInfo *)dirtyRecordTableInfo
{
	YDBLogAutoTrace();
	
	NSParameterAssert(hash != nil);
	NSParameterAssert(dirtyRecordTableInfo != nil);
	
	NSAssert(dirtyRecordTableInfo.dirty_record != nil, @"Logic error");
	NSAssert(dirtyRecordTableInfo.dirty_ownerCount > 0, @"Logic error");
	
	YDBCKRecordKeysRow *recordKeysRow = [YDBCKRecordKeysRow hashRecordKeys:dirtyRecordTableInfo.dirty_record];
	
	BOOL ownerCountChanged = dirtyRecordTableInfo.ownerCountChanged;
	BOOL recordKeysHashChanged = ![recordKeysRow.hash isEqualToString:dirtyRecordTableInfo.clean_recordKeys_hash];
	
	if (!recordKeysHashChanged) {
		recordKeysRow.needsInsert = NO;
	}
	
	if (ownerCountChanged && !recordKeysHashChanged)
	{
		sqlite3_stmt *statement = [parentConnection recordTable_updateOwnerCountStatement];
		if (statement == NULL) {
			return recordKeysRow;
		}
		
		// UPDATE "recordTableName" SET "ownerCount" = ? WHERE "hash" = ?;
		
		int bind_ownerCount = SQLITE_BIND_START + 0;
		int bind_hash       = SQLITE_BIND_START + 1;
		
		sqlite3_bind_int64(statement, bind_ownerCount, dirtyRecordTableInfo.dirty_ownerCount);
		
		YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
		sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
		
		int status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ - Error executing statement (A): %d %s", THIS_METHOD,
						status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_hash);
		
	}
	else if (recordKeysHashChanged)
	{
		// Update recordTable
		
		sqlite3_stmt *statement = [parentConnection recordTable_updateMetadataStatement];
		if (statement == NULL) {
			return recordKeysRow;
		}
		
		// UPDATE "recordTableName" SET "ownerCount" = ?, "recordKeys_hash" = ? WHERE "hash" = ?;
		
		int bind_ownerCount      = SQLITE_BIND_START + 0;
		int bind_recordKeys_hash = SQLITE_BIND_START + 1;
		int bind_hash            = SQLITE_BIND_START + 2;
		
		sqlite3_bind_int64(statement, bind_ownerCount, dirtyRecordTableInfo.dirty_ownerCount);
		
		YapDatabaseString _recordKeys_hash; MakeYapDatabaseString(&_recordKeys_hash, recordKeysRow.hash);
		sqlite3_bind_text(statement, bind_recordKeys_hash,
		                  _recordKeys_hash.str, _recordKeys_hash.length, SQLITE_STATIC);
		
		YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
		sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
		
		int status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ - Error executing statement (B): %d %s", THIS_METHOD,
			            status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_recordKeys_hash);
		FreeYapDatabaseString(&_hash);
	}
	
	return recordKeysRow;
}

- (YDBCKRecordKeysRow *)updateRecordTableRowWithHash:(NSString *)hash
                                              record:(CKRecord *)record
                                  outSanitizedRecord:(CKRecord **)outSanitizedRecord
{
	YDBLogAutoTrace();
	
	NSParameterAssert(hash != nil);
	NSParameterAssert(record != nil);
	
	YDBCKRecordKeysRow *recordKeysRow = [YDBCKRecordKeysRow hashRecordKeys:record];
	
	// Update record table
	
	sqlite3_stmt *statement = [parentConnection recordTable_updateRecordStatement];
	if (statement == NULL)
	{
		if (outSanitizedRecord) *outSanitizedRecord = nil;
		return recordKeysRow;
	}
	
	// UPDATE "recordTableName" SET "recordKeys_hash" = ?, "record" = ? WHERE "hash" = ?;
	
	int bind_recordKeys_hash = SQLITE_BIND_START + 0;
	int bind_record          = SQLITE_BIND_START + 1;
	int bind_hash            = SQLITE_BIND_START + 2;
	
	YapDatabaseString _recordKeys_hash; MakeYapDatabaseString(&_recordKeys_hash, recordKeysRow.hash);
	sqlite3_bind_text(statement, bind_recordKeys_hash, _recordKeys_hash.str, _recordKeys_hash.length, SQLITE_STATIC);
	
	__attribute__((objc_precise_lifetime)) NSData *recordBlob = [YDBCKRecord serializeRecord:record];
	sqlite3_bind_blob(statement, bind_record, recordBlob.bytes, (int)recordBlob.length, SQLITE_STATIC);
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement (A): %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_recordKeys_hash);
	FreeYapDatabaseString(&_hash);
	
	if (outSanitizedRecord) {
		CKRecord *sanitizedRecord = [YDBCKRecord deserializeRecord:recordBlob];
		*outSanitizedRecord = sanitizedRecord;
	}
	return recordKeysRow;
}

- (void)removeRecordTableRowWithHash:(NSString *)hash
{
	YDBLogAutoTrace();
	
	if (hash == nil) {
		YDBLogWarn(@"%@ - Invalid parameter: hash == nil", THIS_METHOD);
		return;
	}
	
	sqlite3_stmt *statement = [parentConnection recordTable_removeForHashStatement];
	if (statement == NULL) {
		return;
	}
	
	// DELETE FROM "recordTableName" WHERE "hash" = ?;
	
	int bind_hash = SQLITE_BIND_START + 0;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	YDBLogVerbose(@"Deleting 1 row from record table with hash(%@)...", hash);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
}

/**
 * This method is invoked from flushPendingChangesToExtensionTables.
 * The given hashes are an summation of all the rows that have been deleted throughout this tranaction.
**/
/*
- (void)removeRecordTableRowsWithHashes:(NSArray *)hashes
{
	YDBLogAutoTrace();
	
	NSUInteger hashesCount = [hashes count];
	
	if (hashesCount == 0) return;
	if (hashesCount == 1)
	{
		[self removeRecordTableRowWithHash:[hashes firstObject]];
		return;
	}
	
	sqlite3 *db = databaseTransaction->connection->db;
	
	NSUInteger maxHostParams = (NSUInteger) sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	
	NSUInteger offset = 0;
	do
	{
		NSUInteger left = hashesCount - offset;
		NSUInteger numParams = MIN(left, maxHostParams);
		
		// DELETE FROM "recordTableName" WHERE "hash" IN (?, ?, ...);
		
		NSUInteger capacity = 60 + (numParams * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendFormat:@"DELETE FROM \"%@\" WHERE \"rowid\" IN (", [self recordTableName]];
		
		for (NSUInteger i = 0; i < numParams; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		int status;
		
		status = sqlite3_prepare_v2(db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@ (%@): Error creating statement\n"
			            @" - status(%d), errmsg: %s\n"
			            @" - query: %@",
			            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db), query);
			
			return;
		}
		
		for (NSUInteger i = 0; i < numParams; i++)
		{
			NSString *hash = [hashes objectAtIndex:i];
			
			sqlite3_bind_text(statement, (int)(i + 1), [hash UTF8String], -1, SQLITE_TRANSIENT);
		}
		
		YDBLogVerbose(@"Deleting %lu rows from records table...", (unsigned long)numParams);
		
		status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ (%@): Error executing statement: %d %s",
						THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
		}
		
		sqlite3_finalize(statement);
		statement = NULL;
		
		offset += numParams;
		
	} while (offset < hashesCount);
	
}
*/

- (void)removeAllRecordTableRows
{
	YDBLogAutoTrace();
	
	sqlite3_stmt *statement = [parentConnection recordTable_removeAllStatement];
	if (statement == NULL) {
		return;
	}
	
	// DELETE FROM "recordTableName";
	
	YDBLogVerbose(@"Deleting all rows from records table...");
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_reset(statement);
}

- (BOOL)getOwnerCount:(int64_t *)ownerCountPtr fromDiskForHash:(NSString *)hash
{
	if (hash == nil) {
		if (ownerCountPtr) *ownerCountPtr = 0;
		return NO;
	}
	
	sqlite3_stmt *statement = [parentConnection recordTable_getOwnerCountForHashStatement];
	if (statement == NULL) {
		if (ownerCountPtr) *ownerCountPtr = 0;
		return NO;
	}
	
	// SELECT "ownerCount" FROM "recordTableName" WHERE "hash" = ?;
	
	int col_ownerCount = SQLITE_COL_START + 0;
	int bind_hash = SQLITE_BIND_START + 0;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	BOOL found = NO;
	int64_t ownerCount = 0;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		found = YES;
		ownerCount = sqlite3_column_int64(statement, col_ownerCount);
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'recordTable_getInfoForHashStatement': %d %s",
					status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
	
	if (ownerCountPtr) *ownerCountPtr = ownerCount;
	return found;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities - RecordKeysTable
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSData *)serializeKeys:(NSArray *)keys
{
	return [NSKeyedArchiver archivedDataWithRootObject:keys];
}

- (NSArray *)deserializeKeys:(NSData *)keysBlob
{
	NSArray *keys = [NSKeyedUnarchiver unarchiveObjectWithData:keysBlob];
	
	if (![keys isKindOfClass:[NSArray class]])
	{
		YDBLogWarn(@"%@ - Found non-array keys: %@", THIS_METHOD, keys);
		return nil;
	}
	else
	{
		return keys;
	}
}

- (void)insertRecordKeysRow:(YDBCKRecordKeysRow *)row
{
	YDBLogAutoTrace();
	
	NSParameterAssert(row.hash != nil);
	NSParameterAssert(row.keys != nil);
	
	sqlite3_stmt *statement = [parentConnection recordKeysTable_insertStatement];
	if (statement == NULL) {
		return;
	}
	
	// INSERT OR IGNORE INTO "recordKeysTable" ("hash", "keys") VALUES (?, ?);
	
	int bind_hash = SQLITE_BIND_START + 0;
	int bind_keys = SQLITE_BIND_START + 1;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, row.hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	__attribute__((objc_precise_lifetime)) NSData *keysBlob = [self serializeKeys:row.keys];
	sqlite3_bind_blob(statement, bind_keys, keysBlob.bytes, (int)keysBlob.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
}

- (NSArray *)keysForRecordKeysHash:(NSString *)hash
{
	YDBLogAutoTrace();
	
	if (hash == nil) return nil;
	
	NSArray *keys = [parentConnection->recordKeysCache objectForKey:hash];
	if (keys) {
		return keys;
	}
	
	sqlite3_stmt *statement = [parentConnection recordKeysTable_getKeysForHashStatement];
	if (statement == NULL) {
		return nil;
	}
	
	// SELECT "keys" FROM "recordKeysTable" WHERE "hash" = ?;
	
	int col_keys = SQLITE_COL_START + 0;
	int bind_hash = SQLITE_BIND_START + 0;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		const void *blob = sqlite3_column_blob(statement, col_keys);
		int blobLen = sqlite3_column_bytes(statement, col_keys);
		
		NSData *data = [NSData dataWithBytesNoCopy:(void *)blob length:blobLen freeWhenDone:NO];
		
		keys = [self deserializeKeys:data];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@: Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
	
	if (keys) {
		[parentConnection->recordKeysCache setObject:keys forKey:hash];
	}
	
	return keys;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities - QueueTable
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Invoke this method with the NEW changeSets from the pendingQueue (pendingQueue.newChangeSets).
**/
- (NSDictionary *)insertQueueTableRowWithChangeSet:(YDBCKChangeSet *)changeSet
{
	YDBLogAutoTrace();
	
	sqlite3_stmt *statement = [parentConnection queueTable_insertStatement];
	if (statement == NULL) {
		return nil;
	}
	
	NSDictionary *recordKeysRowDict = nil;
	
	// INSERT INTO "queueTableName"
	//   ("uuid", "prev", "databaseIdentifier", "deletedRecordIDs", "modifiedRecords") VALUES (?, ?, ?, ?, ?);
	
	int bind_uuid             = SQLITE_BIND_START + 0;
	int bind_prev             = SQLITE_BIND_START + 1;
	int bind_dbid             = SQLITE_BIND_START + 2;
	int bind_deletedRecordIDs = SQLITE_BIND_START + 3;
	int bind_modifiedRecords  = SQLITE_BIND_START + 4;
	
	YapDatabaseString _uuid; MakeYapDatabaseString(&_uuid, changeSet.uuid);
	sqlite3_bind_text(statement, bind_uuid, _uuid.str, _uuid.length, SQLITE_STATIC);
	
	YapDatabaseString _prev; MakeYapDatabaseString(&_prev, changeSet.prev);
	sqlite3_bind_text(statement, bind_prev, _prev.str, _prev.length, SQLITE_STATIC);
	
	YapDatabaseString _dbid; MakeYapDatabaseString(&_dbid, changeSet.databaseIdentifier);
	if (changeSet.databaseIdentifier)
		sqlite3_bind_text(statement, bind_dbid, _dbid.str, _dbid.length, SQLITE_STATIC);
	else
		sqlite3_bind_null(statement, bind_dbid);
	
	__attribute__((objc_precise_lifetime)) NSData *blob1 = [changeSet serializeDeletedRecordIDs];
	if (blob1)
		sqlite3_bind_blob(statement, bind_deletedRecordIDs, blob1.bytes, (int)blob1.length, SQLITE_STATIC);
	else
		sqlite3_bind_null(statement, bind_deletedRecordIDs);
	
	__attribute__((objc_precise_lifetime)) NSData *blob2 = [changeSet serializeModifiedRecords:&recordKeysRowDict];
	if (blob2)
		sqlite3_bind_blob(statement, bind_modifiedRecords, blob2.bytes, (int)blob2.length, SQLITE_STATIC);
	else
		sqlite3_bind_null(statement, bind_modifiedRecords);
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_uuid);
	FreeYapDatabaseString(&_prev);
	FreeYapDatabaseString(&_dbid);
	
	return recordKeysRowDict;
}

/**
 * Invoke this method with OLDER changeSets from the pendingQueue that have changes we need to write to the DB.
**/
- (NSDictionary *)updateQueueTableRowWithChangeSet:(YDBCKChangeSet *)changeSet
{
	YDBLogAutoTrace();
	
	NSAssert(changeSet.hasChangesToDeletedRecordIDs || changeSet.hasChangesToModifiedRecords,
	         @"Method expected modified changeSet !");
	
	NSDictionary *recordKeysRowDict = nil;
	
	if (changeSet.hasChangesToDeletedRecordIDs && !changeSet.hasChangesToModifiedRecords)
	{
		// Update column(s):
		// - deletedRecordIDs
		
		sqlite3_stmt *statement = [parentConnection queueTable_updateDeletedRecordIDsStatement];
		if (statement == NULL) {
			return nil;
		}
		
		// UPDATE "queueTableName" SET "deletedRecordIDs" = ? WHERE "uuid" = ?;
		
		int bind_deletedRecordIDs = SQLITE_BIND_START + 0;
		int bind_uuid             = SQLITE_BIND_START + 1;
		
		__attribute__((objc_precise_lifetime)) NSData *blob = [changeSet serializeDeletedRecordIDs];
		if (blob)
			sqlite3_bind_blob(statement, bind_deletedRecordIDs, blob.bytes, (int)blob.length, SQLITE_STATIC);
		else
			sqlite3_bind_null(statement, bind_deletedRecordIDs);
		
		YapDatabaseString _uuid; MakeYapDatabaseString(&_uuid, changeSet.uuid);
		sqlite3_bind_text(statement, bind_uuid, _uuid.str, _uuid.length, SQLITE_STATIC);
		
		int status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
			            status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_uuid);
	}
	else if (!changeSet.hasChangesToDeletedRecordIDs && changeSet.hasChangesToModifiedRecords)
	{
		// Update column(s):
		// - modifiedRecords
		
		sqlite3_stmt *statement = [parentConnection queueTable_updateModifiedRecordsStatement];
		if (statement == NULL) {
			return nil;
		}
		
		// UPDATE "queueTableName" SET "modifiedRecords" = ? WHERE "uuid" = ?;
		
		int bind_modifiedRecords = SQLITE_BIND_START + 0;
		int bind_uuid            = SQLITE_BIND_START + 1;
		
		__attribute__((objc_precise_lifetime)) NSData *blob = [changeSet serializeModifiedRecords:&recordKeysRowDict];
		if (blob)
			sqlite3_bind_blob(statement, bind_modifiedRecords, blob.bytes, (int)blob.length, SQLITE_STATIC);
		else
			sqlite3_bind_null(statement, bind_modifiedRecords);
		
		YapDatabaseString _uuid; MakeYapDatabaseString(&_uuid, changeSet.uuid);
		sqlite3_bind_text(statement, bind_uuid, _uuid.str, _uuid.length, SQLITE_STATIC);
		
		int status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
			            status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_uuid);
	}
	else if (changeSet.hasChangesToDeletedRecordIDs && changeSet.hasChangesToModifiedRecords)
	{
		// Update column(s):
		// - deletedRecordIDs
		// - modifiedRecords
		
		sqlite3_stmt *statement = [parentConnection queueTable_updateBothStatement];
		if (statement == NULL) {
			return nil;
		}
		
		// UPDATE "queueTableName" SET "deletedRecordIDs" = ?, "modifiedRecords" = ? WHERE "uuid" = ?;
		
		int bind_deletedRecordIDs = SQLITE_BIND_START + 0;
		int bind_modifiedRecods   = SQLITE_BIND_START + 1;
		int bind_uuid             = SQLITE_BIND_START + 2;
		
		__attribute__((objc_precise_lifetime)) NSData *drBlob = [changeSet serializeDeletedRecordIDs];
		if (drBlob)
			sqlite3_bind_blob(statement, bind_deletedRecordIDs, drBlob.bytes, (int)drBlob.length, SQLITE_STATIC);
		else
			sqlite3_bind_null(statement, bind_deletedRecordIDs);
		
		__attribute__((objc_precise_lifetime)) NSData *mrBlob = [changeSet serializeModifiedRecords:&recordKeysRowDict];
		if (mrBlob)
			sqlite3_bind_blob(statement, bind_modifiedRecods, mrBlob.bytes, (int)mrBlob.length, SQLITE_STATIC);
		else
			sqlite3_bind_null(statement, bind_modifiedRecods);
		
		YapDatabaseString _uuid; MakeYapDatabaseString(&_uuid, changeSet.uuid);
		sqlite3_bind_text(statement, bind_uuid, _uuid.str, _uuid.length, SQLITE_STATIC);
		
		int status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
			            status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_uuid);
	}
	
	return recordKeysRowDict;
}

/**
 * This method is invoked by [YapDatabaseCloudKit handleCompletedOperation:withSavedRecords:].
**/
- (void)removeQueueTableRowWithUUID:(NSString *)uuid
{
	YDBLogAutoTrace();
	
	// Execute that sqlite statement.
	
	sqlite3_stmt *statement = [parentConnection queueTable_removeForUuidStatement];
	if (statement == NULL) {
		return;
	}
	
	// DELETE FROM "queueTableName" WHERE "uuid" = ?;
	
	int bind_uuid = SQLITE_BIND_START + 0;
	
	YapDatabaseString _uuid; MakeYapDatabaseString(&_uuid, uuid);
	sqlite3_bind_text(statement, bind_uuid, _uuid.str, _uuid.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_uuid);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Completion
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)handlePartiallyCompletedOperationWithChangeSet:(YDBCKChangeSet *)changeSet
                                          savedRecords:(NSArray *)savedRecords
                                      deletedRecordIDs:(NSArray *)deletedRecordIDs
{
	YDBLogAutoTrace();
	
	// Proper API usage check
	if (!databaseTransaction->isReadWriteTransaction)
	{
		@throw [self requiresReadWriteTransactionException:NSStringFromSelector(_cmd)];
		return;
	}
	
	// Step 1 of 7:
	//
	// Mark this transaction as an operationPartialCompletionTransaction.
	// This is handled a little differently from a regular (user-initiated) transaction.
	
	parentConnection->isOperationPartialCompletionTransaction = YES;
	
	// Step 2 of 7:
	//
	// Update recordsTable & recordsCache for any records that were saved.
	// We need to store the new system fields of the CKRecord.
	
	NSMutableDictionary *recordKeysTableChanges = nil;
	
	NSUInteger capacity = savedRecords.count;
	if (capacity > 0) {
		recordKeysTableChanges = [NSMutableDictionary dictionaryWithCapacity:capacity];
	}
	
	for (CKRecord *record in savedRecords)
	{
		NSString *hash = [self hashRecordID:record.recordID databaseIdentifier:changeSet.databaseIdentifier];
		
		YDBCKRecordKeysRow *recordKeysRow = nil;
		CKRecord *sanitizedRecord = nil;
		
		recordKeysRow = [self updateRecordTableRowWithHash:hash
		                                            record:record
		                                outSanitizedRecord:&sanitizedRecord];
		
		if (recordKeysRow.needsInsert)
		{
			[recordKeysTableChanges setObject:recordKeysRow forKey:recordKeysRow.hash];
		}
		
		if (sanitizedRecord)
		{
			YDBCKCleanRecordTableInfo *cleanRecordTableInfo;
			
			cleanRecordTableInfo = [parentConnection->cleanRecordTableInfoCache objectForKey:hash];
			if (cleanRecordTableInfo)
			{
				cleanRecordTableInfo = [cleanRecordTableInfo cleanCopyWithRecordKeys_hash:recordKeysRow.hash
				                                                          sanitizedRecord:sanitizedRecord];
				
				[parentConnection->cleanRecordTableInfoCache setObject:cleanRecordTableInfo forKey:hash];
			}
			else
			{
				int64_t ownerCount = 0;
				[self getOwnerCount:&ownerCount fromDiskForHash:hash];
				
				cleanRecordTableInfo =
				  [[YDBCKCleanRecordTableInfo alloc] initWithDatabaseIdentifier:changeSet.databaseIdentifier
				                                                     ownerCount:ownerCount
				                                                recordKeys_hash:recordKeysRow.hash
				                                                         record:sanitizedRecord];
			}
			
			if (parentConnection->changeset_recordTableInfo == nil) {
				parentConnection->changeset_recordTableInfo = [NSMutableDictionary dictionary];
			}
			[parentConnection->changeset_recordTableInfo setObject:cleanRecordTableInfo forKey:hash];
		}
		else
		{
			if (parentConnection->changeset_deletedHashes == nil) {
				parentConnection->changeset_deletedHashes = [NSMutableSet set];
			}
			[parentConnection->changeset_deletedHashes addObject:hash];
		}
	}
	
	// Step 3 of 7:
	//
	// Create a pendingQueue,
	// and lock the masterQueue so we can make changes to it.
	//
	// Note: Creating a pendingQueue automatically locks the masterQueue.
	
	YDBCKChangeQueue *masterQueue = parentConnection->parent->masterQueue;
	YDBCKChangeQueue *pendingQueue = [masterQueue newPendingQueue];
	
	// Step 4 of 7:
	//
	// Update previous changeSets (if needed), including the inFlightChangeSet.
	
	for (CKRecord *savedRecord in savedRecords)
	{
		[masterQueue updatePendingQueue:pendingQueue
		                withSavedRecord:savedRecord
		             databaseIdentifier:changeSet.databaseIdentifier
				  isOpPartialCompletion:YES];
	}
	
	for (CKRecordID *deletedRecordID in deletedRecordIDs)
	{
		[masterQueue updatePendingQueue:pendingQueue
		       withSavedDeletedRecordID:deletedRecordID
		             databaseIdentifier:changeSet.databaseIdentifier];
	}
	
	// Step 5 of 7:
	//
	// Update queue table.
	// This is the list of changes the pendingQueue gives us.
	
	for (YDBCKChangeSet *oldChangeSet in pendingQueue.changeSetsFromPreviousCommits)
	{
		if (oldChangeSet.hasChangesToDeletedRecordIDs || oldChangeSet.hasChangesToModifiedRecords)
		{
			NSDictionary *recordKeysRowDict = [self updateQueueTableRowWithChangeSet:oldChangeSet];
			if (recordKeysRowDict)
			{
				[recordKeysTableChanges addEntriesFromDictionary:recordKeysRowDict];
			}
		}
	}
	
	// Step 6 of 7:
	//
	// Update the masterQueue,
	// and unlock it so the next operation can be dispatched.
	
	[masterQueue mergePendingQueue:pendingQueue];
	
	// Step 7 of 7:
	//
	// Update recordKeys table.
	
	for (YDBCKRecordKeysRow *recordKeysRow in [recordKeysTableChanges objectEnumerator])
	{
		[self insertRecordKeysRow:recordKeysRow];
	}
}

- (void)handleCompletedOperationWithChangeSet:(YDBCKChangeSet *)changeSet
                                 savedRecords:(NSArray *)savedRecords
                             deletedRecordIDs:(NSArray *)deletedRecordIDs
{
	YDBLogAutoTrace();
	
	// Proper API usage check
	if (!databaseTransaction->isReadWriteTransaction)
	{
		@throw [self requiresReadWriteTransactionException:NSStringFromSelector(_cmd)];
		return;
	}
	
	NSMutableDictionary *recordKeysTableChanges = [NSMutableDictionary dictionary];
	
	// Step 1 of 7:
	//
	// Mark this transaction as an operationCompletionTransaction.
	// This is handled a little differently from a regular (user-initiated) transaction.
	
	parentConnection->isOperationCompletionTransaction = YES;
	
	// Step 2 of 7:
	//
	// Update recordsTable & recordsCache for any records that were saved.
	// We need to store the new system fields of the CKRecord.
	
	for (CKRecord *record in savedRecords)
	{
		NSString *hash = [self hashRecordID:record.recordID databaseIdentifier:changeSet.databaseIdentifier];
		
		YDBCKRecordKeysRow *recordKeysRow = nil;
		CKRecord *sanitizedRecord = nil;
		
		recordKeysRow = [self updateRecordTableRowWithHash:hash
		                                            record:record
		                                outSanitizedRecord:&sanitizedRecord];
		
		if (recordKeysRow.needsInsert)
		{
			[recordKeysTableChanges setObject:recordKeysRow forKey:recordKeysRow.hash];
		}
		
		if (sanitizedRecord)
		{
			YDBCKCleanRecordTableInfo *cleanRecordTableInfo;
			
			cleanRecordTableInfo = [parentConnection->cleanRecordTableInfoCache objectForKey:hash];
			if (cleanRecordTableInfo)
			{
				cleanRecordTableInfo = [cleanRecordTableInfo cleanCopyWithRecordKeys_hash:recordKeysRow.hash
				                                                          sanitizedRecord:sanitizedRecord];
				
				[parentConnection->cleanRecordTableInfoCache setObject:cleanRecordTableInfo forKey:hash];
			}
			else
			{
				int64_t ownerCount = 0;
				[self getOwnerCount:&ownerCount fromDiskForHash:hash];
				
				cleanRecordTableInfo =
				  [[YDBCKCleanRecordTableInfo alloc] initWithDatabaseIdentifier:changeSet.databaseIdentifier
				                                                     ownerCount:ownerCount
				                                                recordKeys_hash:recordKeysRow.hash
				                                                         record:sanitizedRecord];
				
				[parentConnection->cleanRecordTableInfoCache setObject:cleanRecordTableInfo forKey:hash];
			}
			
			if (parentConnection->changeset_recordTableInfo == nil) {
				parentConnection->changeset_recordTableInfo = [NSMutableDictionary dictionary];
			}
			[parentConnection->changeset_recordTableInfo setObject:cleanRecordTableInfo forKey:hash];
		}
		else
		{
			if (parentConnection->changeset_deletedHashes == nil) {
				parentConnection->changeset_deletedHashes = [NSMutableSet set];
			}
			[parentConnection->changeset_deletedHashes addObject:hash];
		}

	}
	
	// Step 3 of 7:
	//
	// Create a pendingQueue,
	// and lock the masterQueue so we can make changes to it.
	//
	// Note: Creating a pendingQueue automatically locks the masterQueue.
	
	YDBCKChangeQueue *masterQueue = parentConnection->parent->masterQueue;
	YDBCKChangeQueue *pendingQueue = [masterQueue newPendingQueue];
	
	// Step 4 of 7:
	//
	// Update previous changeSets (if needed).
	//
	// Note: There's no need to update the inFlightChangeSet.
	// Since this operation completed successfully, we're just going to delete the inFlightChangeSet anyway.
	
	for (CKRecord *savedRecord in savedRecords)
	{
		[masterQueue updatePendingQueue:pendingQueue
		                withSavedRecord:savedRecord
		             databaseIdentifier:changeSet.databaseIdentifier
		          isOpPartialCompletion:NO];
	}
	
	// Step 5 of 7:
	//
	// Update queue table.
	// This is the list of changes the pendingQueue gives us.
	
	for (YDBCKChangeSet *queuedChangeSet in pendingQueue.changeSetsFromPreviousCommits)
	{
		if (queuedChangeSet.hasChangesToDeletedRecordIDs || queuedChangeSet.hasChangesToModifiedRecords)
		{
			NSAssert(![queuedChangeSet.uuid isEqualToString:changeSet.uuid], @"Logic error");
			
			NSDictionary *recordKeysRowDict = [self updateQueueTableRowWithChangeSet:queuedChangeSet];
			if (recordKeysRowDict)
			{
				[recordKeysTableChanges addEntriesFromDictionary:recordKeysRowDict];
			}
		}
	}
	
	[self removeQueueTableRowWithUUID:changeSet.uuid];
	
	// Step 6 of 7:
	//
	// Update the masterQueue,
	// and unlock it so the next operation can be dispatched.
	
	[masterQueue mergePendingQueue:pendingQueue];
	
	// Step 7 of 7:
	//
	// Update recordKeys table.
	
	for (YDBCKRecordKeysRow *recordKeysRow in [recordKeysTableChanges objectEnumerator])
	{
		[self insertRecordKeysRow:recordKeysRow];
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Cleanup & Commit
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Subclasses MUST implement this method.
 * This method is only called if within a readwrite transaction.
 *
 * Subclasses should write any last changes to their database table(s) if needed,
 * and should perform any needed cleanup before the changeset is requested.
 *
 * Remember, the changeset is requested immediately after this method is invoked.
**/
- (void)flushPendingChangesToExtensionTables
{
	YDBLogAutoTrace();
	
	if (parentConnection->isOperationCompletionTransaction)
	{
		// Nothing to do here.
		// We already handled everything in
		//   'handleCompletedOperationWithChangeSet:savedRecords:deletedRecordIDs:'.
		return;
	}
	if (parentConnection->isOperationPartialCompletionTransaction)
	{
		// Nothing to do here.
		// We already handled everything in
		//   'handlePartiallyCompletedOperationWithChangeSet:savedRecords:deletedRecordIDs:'
		return;
	}
	
	if ((parentConnection->dirtyMappingTableInfoDict.count == 0) &&
	    (parentConnection->dirtyRecordTableInfoDict.count  == 0))
	{
		// Nothing affecting YapDatabaseCloudKit was changed in this transaction.
		return;
	}
	
	NSMutableDictionary *recordKeysTableChanges = [NSMutableDictionary dictionary];
	
	// Step 1 of 7:
	//
	// Update mapping table.
	
	[parentConnection->dirtyMappingTableInfoDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		__unsafe_unretained NSNumber *rowidNumber = (NSNumber *)key;
		__unsafe_unretained YDBCKDirtyMappingTableInfo *dirtyMappingTableInfo = (YDBCKDirtyMappingTableInfo *)obj;
		
		if (dirtyMappingTableInfo.dirty_recordTable_hash == nil)
		{
			[self removeMappingTableRowWithRowid:[rowidNumber longLongValue]];
			
			if (parentConnection->changeset_deletedRowids == nil)
				parentConnection->changeset_deletedRowids = [[NSMutableSet alloc] init];
			
			[parentConnection->changeset_deletedRowids addObject:rowidNumber];
		}
		else
		{
			[self insertOrUpdateMappingTableRowWithRowid:[rowidNumber longLongValue] info:dirtyMappingTableInfo];
			
			YDBCKCleanMappingTableInfo *cleanMappingTableInfo = [dirtyMappingTableInfo cleanCopy];
			
			if (parentConnection->changeset_mappingTableInfo == nil)
				parentConnection->changeset_mappingTableInfo = [[NSMutableDictionary alloc] init];
			
			[parentConnection->changeset_mappingTableInfo setObject:cleanMappingTableInfo forKey:rowidNumber];
			[parentConnection->cleanMappingTableInfoCache setObject:cleanMappingTableInfo forKey:rowidNumber];
		}
	}];
	
	// Step 2 of 7:
	//
	// Update record table.
	
	[parentConnection->dirtyRecordTableInfoDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		__unsafe_unretained NSString *hash = (NSString *)key;
		__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = (YDBCKDirtyRecordTableInfo *)obj;
		
		if ([dirtyRecordTableInfo hasNilRecordOrZeroOwnerCount])
		{
			if (dirtyRecordTableInfo.clean_ownerCount <= 0)
			{
				// We were just updating CKRecords in the queue.
				// We've already deleted/detached the CKRecord, so it's not in the record table.
			}
			else
			{
				[self removeRecordTableRowWithHash:hash];
				
				if (parentConnection->changeset_deletedHashes == nil)
					parentConnection->changeset_deletedHashes = [[NSMutableSet alloc] init];
				
				[parentConnection->changeset_deletedHashes addObject:hash];
			}
		}
		else
		{
			YDBCKRecordKeysRow *recordKeysRow = nil;
			CKRecord *sanitizedRecord = nil;
			
			if (dirtyRecordTableInfo.clean_ownerCount <= 0)
			{
				recordKeysRow = [self insertRecordTableRowWithHash:hash
				                                              info:dirtyRecordTableInfo
				                                outSanitizedRecord:&sanitizedRecord];
			}
			else
			{
				// There's no use in us writing the record to the database right now.
				// We only write the system fields anyway, and they have not changed yet.
				// They won't be changed until the corresponding CKModifyRecordsOperation completes.
				// And it's at that point that we'll write the updated record to the database.
				
				sanitizedRecord = [dirtyRecordTableInfo.dirty_record sanitizedCopy];
				
				// We may, however, need to update the metadata about the record.
				// That is, the ownerCount and/or recordKeys_hash value(s).
				
				recordKeysRow = [self maybeUpdateRecordTableRowWithHash:hash info:dirtyRecordTableInfo];
			}
			
			if (recordKeysRow.needsInsert)
			{
				[recordKeysTableChanges setObject:recordKeysRow forKey:recordKeysRow.hash];
			}
			
			YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
			  [dirtyRecordTableInfo cleanCopyWithRecordKeys_hash:recordKeysRow.hash
			                                     sanitizedRecord:sanitizedRecord];
			
			if (parentConnection->changeset_recordTableInfo == nil)
				parentConnection->changeset_recordTableInfo = [[NSMutableDictionary alloc] init];
			
			[parentConnection->changeset_recordTableInfo setObject:cleanRecordTableInfo forKey:hash];
			[parentConnection->cleanRecordTableInfoCache setObject:cleanRecordTableInfo forKey:hash];
		}
	}];
	
	// Step 3 of 7:
	//
	// Create a pendingQueue,
	// and lock the masterQueue so we can make changes to it.
	
	YDBCKChangeQueue *masterQueue = parentConnection->parent->masterQueue;
	YDBCKChangeQueue *pendingQueue = [masterQueue newPendingQueue];
	
	// Step 4 of 7:
	//
	// Use YDBCKChangeQueue tools to generate a list of updates for the queue table.
	
	[parentConnection->dirtyRecordTableInfoDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
	//	__unsafe_unretained NSString *hash = (NSString *)key;
		__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = (YDBCKDirtyRecordTableInfo *)obj;
		
		if ([dirtyRecordTableInfo hasNilRecordOrZeroOwnerCount])
		{
			// The CKRecord has been deleted via one of the following:
			//
			// - [transaction removeObjectForKey:inCollection:]
			// - [[transaction ext:ck] deleteRecordForKey:inCollection]
			// - [[transaction ext:ck] detachKey:inCollection]
			//
			// Note: In the detached scenario, the user wants us to "detach" the local row
			// from its associated CKRecord, but not to actually delete the CKRecord from the cloud.
			
			if (dirtyRecordTableInfo.clean_ownerCount <= 0 &&
			    dirtyRecordTableInfo.dirty_record &&
			    dirtyRecordTableInfo.remoteMerge)
			{
				// We were just updating CKRecords in the queue.
				// We've already deleted/detached the CKRecord, so it's not in the record table.
				
				[masterQueue updatePendingQueue:pendingQueue
				               withMergedRecord:dirtyRecordTableInfo.dirty_record
				             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
			}
			else if (dirtyRecordTableInfo.remoteDeletion)
			{
				[masterQueue updatePendingQueue:pendingQueue
				      withRemoteDeletedRecordID:dirtyRecordTableInfo.recordID
				             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
			}
			else if (dirtyRecordTableInfo.skipUploadDeletion)
			{
				[masterQueue updatePendingQueue:pendingQueue
				           withDetachedRecordID:dirtyRecordTableInfo.recordID
				             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
			}
			else
			{
				[masterQueue updatePendingQueue:pendingQueue
				            withDeletedRecordID:dirtyRecordTableInfo.recordID
				             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
			}
		}
		else
		{
			// The CKRecord has been modified via one or more of the following:
			//
			// - [transaction setObject:forKey:inCollection:]
			// - [[transaction ext:ck] detachKey:inCollection:]
			// - [[transaction ext:ck] attachRecord:forKey:inCollection:]
			
			if (dirtyRecordTableInfo.clean_ownerCount <= 0)
			{
				// Newly inserted record
				
				if (dirtyRecordTableInfo.remoteMerge)
				{
					[masterQueue updatePendingQueue:pendingQueue
					               withMergedRecord:dirtyRecordTableInfo.dirty_record
					             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
				}
				else if (dirtyRecordTableInfo.skipUploadRecord == NO)
				{
					[masterQueue updatePendingQueue:pendingQueue
					             withInsertedRecord:dirtyRecordTableInfo.dirty_record
					             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
				}
			}
			else
			{
				// Modified record
				
				if (dirtyRecordTableInfo.remoteMerge)
				{
					[masterQueue updatePendingQueue:pendingQueue
					               withMergedRecord:dirtyRecordTableInfo.dirty_record
					             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
				}
				else if (dirtyRecordTableInfo.skipUploadRecord == NO)
				{
					[masterQueue updatePendingQueue:pendingQueue
					             withModifiedRecord:dirtyRecordTableInfo.dirty_record
					             databaseIdentifier:dirtyRecordTableInfo.databaseIdentifier];
				}
			}
		}
	}];
	
	// Step 5 of 7:
	//
	// Update queue table.
	// This is the list of changes the pendingQueue gives us.
	
	for (YDBCKChangeSet *oldChangeSet in pendingQueue.changeSetsFromPreviousCommits)
	{
		if (oldChangeSet.hasChangesToDeletedRecordIDs || oldChangeSet.hasChangesToModifiedRecords)
		{
			NSDictionary *recordKeysRowDict = [self updateQueueTableRowWithChangeSet:oldChangeSet];
			if (recordKeysRowDict)
			{
				[recordKeysTableChanges addEntriesFromDictionary:recordKeysRowDict];
			}
		}
	}
	
	for (YDBCKChangeSet *newChangeSet in pendingQueue.changeSetsFromCurrentCommit)
	{
		NSDictionary *recordKeysRowDict = [self insertQueueTableRowWithChangeSet:newChangeSet];
		if (recordKeysRowDict)
		{
			[recordKeysTableChanges addEntriesFromDictionary:recordKeysRowDict];
		}
	}
	
	// Step 6 of 7:
	//
	// Update the masterQueue,
	// and unlock it so the next operation can be dispatched.
	
	[masterQueue mergePendingQueue:pendingQueue];
	
	// Step 7 of 7:
	//
	// Update recordKeys table
	
	for (YDBCKRecordKeysRow *recordKeysRow in [recordKeysTableChanges objectEnumerator])
	{
		[self insertRecordKeysRow:recordKeysRow];
	}
}

/**
 * Required override method from YapDatabaseExtensionTransaction.
**/
- (void)didCommitTransaction
{
	YDBLogAutoTrace();
	
	// Forward to connection for further cleanup.
	
	[parentConnection postCommitCleanup];
	
	// An extensionTransaction is only valid within the scope of its encompassing databaseTransaction.
	// I imagine this may occasionally be misunderstood, and developers may attempt to store the extension in an ivar,
	// and then use it outside the context of the database transaction block.
	// Thus, this code is here as a safety net to ensure that such accidental misuse doesn't do any damage.
	
	parentConnection = nil;    // Do not remove !
	databaseTransaction = nil; // Do not remove !
}

/**
 * Required override method from YapDatabaseExtensionTransaction.
**/
- (void)didRollbackTransaction
{
	YDBLogAutoTrace();
	
	// Forward to connection for further cleanup.
	
	[parentConnection postRollbackCleanup];
	
	// An extensionTransaction is only valid within the scope of its encompassing databaseTransaction.
	// I imagine this may occasionally be misunderstood, and developers may attempt to store the extension in an ivar,
	// and then use it outside the context of the database transaction block.
	// Thus, this code is here as a safety net to ensure that such accidental misuse doesn't do any damage.

	parentConnection = nil;    // Do not remove !
	databaseTransaction = nil; // Do not remove !
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Transaction Hooks
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleInsertObject:(id)object
          forCollectionKey:(YapCollectionKey *)collectionKey
              withMetadata:(id)metadata
                     rowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	__unsafe_unretained NSString *collection = collectionKey.collection;
	__unsafe_unretained NSString *key = collectionKey.key;
	
	YapWhitelistBlacklist *allowedCollections = parentConnection->parent->options.allowedCollections;
	
	if (allowedCollections && ![allowedCollections isAllowed:collection])
	{
		return;
	}
	
	// Check for pending attach request
	
	YDBCKAttachRequest *attachRequest = [parentConnection->pendingAttachRequests objectForKey:collectionKey];
	if (attachRequest)
	{
		CKRecord *record = attachRequest.record;
		NSString *databaseIdentifier = attachRequest.databaseIdentifier;
		
		YDBCKProcessRecordBitMask flags = 0;
		if (!attachRequest.shouldUploadRecord)
			flags |= YDBCK_skipUploadRecord;
		
		[self processRecord:record databaseIdentifier:databaseIdentifier
		                            preCalculatedHash:nil
		                                     forRowid:rowid
		                     withPrevMappingTableInfo:nil
		                          prevRecordTableInfo:nil
		                                        flags:flags];
		
		[parentConnection->pendingAttachRequests removeObjectForKey:collectionKey];
		return;
	}
	
	// Invoke the recordBlock.
	
	YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
	CKRecord *record = nil;
	
	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithKeyBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithKeyBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key);
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithObjectBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithObjectBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, object);
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithMetadataBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithMetadataBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, metadata);
	}
	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, object, metadata);
	}
	
	// Figure if anything changed, and schedule updates to the table(s) accordingly
	
	[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
	                            preCalculatedHash:nil
	                                     forRowid:rowid
	                     withPrevMappingTableInfo:nil
	                          prevRecordTableInfo:nil
	                                        flags:0];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleUpdateObject:(id)object
          forCollectionKey:(YapCollectionKey *)collectionKey
              withMetadata:(id)metadata
                     rowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	__unsafe_unretained NSString *collection = collectionKey.collection;
	__unsafe_unretained NSString *key = collectionKey.key;
	
	YapWhitelistBlacklist *allowedCollections = parentConnection->parent->options.allowedCollections;
	
	if (allowedCollections && ![allowedCollections isAllowed:collection])
	{
		return;
	}
	
	// Fetch current mappings & record information for the given rowid.
	
	id <YDBCKMappingTableInfo> mappingTableInfo = nil;
	id <YDBCKRecordTableInfo> recordTableInfo = nil;
	
	mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:YES];
	if (mappingTableInfo) {
		recordTableInfo = [self recordTableInfoForHash:mappingTableInfo.current_recordTable_hash cacheResult:YES];
	}
	
	CKRecord *record = nil;
	if ([recordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
		  (YDBCKCleanRecordTableInfo *)recordTableInfo;
		
		record = [cleanRecordTableInfo.record safeCopy];
	}
	else if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		  (YDBCKDirtyRecordTableInfo *)recordTableInfo;
		
		record = dirtyRecordTableInfo.dirty_record;
	}
	
	YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
	recordInfo.databaseIdentifier = recordTableInfo.databaseIdentifier;
	
	// Invoke the recordBlock.
	
	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithKeyBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithKeyBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key);
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithObjectBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithObjectBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, object);
	}
	else if (recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithMetadataBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithMetadataBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, metadata);
	}
	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, object, metadata);
	}
	
	// Figure if anything changed, and schedule updates to the table(s) accordingly
	
	[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
	                            preCalculatedHash:nil
	                                     forRowid:rowid
	                     withPrevMappingTableInfo:mappingTableInfo
	                          prevRecordTableInfo:recordTableInfo
	                                        flags:0];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleReplaceObject:(id)object forCollectionKey:(YapCollectionKey *)collectionKey withRowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	__unsafe_unretained NSString *collection = collectionKey.collection;
	__unsafe_unretained NSString *key = collectionKey.key;
	
	YapWhitelistBlacklist *allowedCollections = parentConnection->parent->options.allowedCollections;
	
	if (allowedCollections && ![allowedCollections isAllowed:collection])
	{
		return;
	}
	
	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey     ||
	    recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata )
	{
		// Nothing to do.
		// The collection/key/metadata hasn't changed, so the CKRecord hasn't changed.
		
		return;
	}
	
	// Fetch current mappings & record information for the given rowid.
	
	id <YDBCKMappingTableInfo> mappingTableInfo = nil;
	id <YDBCKRecordTableInfo> recordTableInfo = nil;
	
	mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:YES];
	if (mappingTableInfo) {
		recordTableInfo = [self recordTableInfoForHash:mappingTableInfo.current_recordTable_hash cacheResult:YES];
	}
	
	CKRecord *record = nil;
	if ([recordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
		(YDBCKCleanRecordTableInfo *)recordTableInfo;
		
		record = [cleanRecordTableInfo.record safeCopy];
	}
	else if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		(YDBCKDirtyRecordTableInfo *)recordTableInfo;
		
		record = dirtyRecordTableInfo.dirty_record;
	}
	
	YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
	recordInfo.databaseIdentifier = recordTableInfo.databaseIdentifier;
	
	// Invoke the recordBlock.
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithObjectBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithObjectBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, object);
	}
	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
		
		id metadata = [databaseTransaction metadataForCollectionKey:collectionKey withRowid:rowid];
		
		recordBlock(&record, recordInfo, collection, key, object, metadata);
	}
	
	// Figure if anything changed, and schedule updates to the table(s) accordingly
	
	[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
	                            preCalculatedHash:nil
	                                     forRowid:rowid
	                     withPrevMappingTableInfo:mappingTableInfo
	                          prevRecordTableInfo:recordTableInfo
	                                        flags:0];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleReplaceMetadata:(id)metadata forCollectionKey:(YapCollectionKey *)collectionKey withRowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	__unsafe_unretained NSString *collection = collectionKey.collection;
	__unsafe_unretained NSString *key = collectionKey.key;
	
	YapWhitelistBlacklist *allowedCollections = parentConnection->parent->options.allowedCollections;
	
	if (allowedCollections && ![allowedCollections isAllowed:collection])
	{
		return;
	}
	
	YapDatabaseCloudKitBlockType recordBlockType = parentConnection->parent->recordBlockType;
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithKey   ||
		recordBlockType == YapDatabaseCloudKitBlockTypeWithObject )
	{
		// Nothing to do.
		// The collection/key/object hasn't changed, so the CKRecord hasn't changed.
		
		return;
	}
	
	// Fetch current mappings & record information for the given rowid.
	
	id <YDBCKMappingTableInfo> mappingTableInfo = nil;
	id <YDBCKRecordTableInfo> recordTableInfo = nil;
	
	mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:YES];
	if (mappingTableInfo) {
		recordTableInfo = [self recordTableInfoForHash:mappingTableInfo.current_recordTable_hash cacheResult:YES];
	}
	
	CKRecord *record = nil;
	if ([recordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
		(YDBCKCleanRecordTableInfo *)recordTableInfo;
		
		record = [cleanRecordTableInfo.record safeCopy];
	}
	else if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		(YDBCKDirtyRecordTableInfo *)recordTableInfo;
		
		record = dirtyRecordTableInfo.dirty_record;
	}
	
	YDBCKRecordInfo *recordInfo = [[YDBCKRecordInfo alloc] init];
	recordInfo.databaseIdentifier = recordTableInfo.databaseIdentifier;
	
	// Invoke the recordBlock.
	
	if (recordBlockType == YapDatabaseCloudKitBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithMetadataBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithMetadataBlock)parentConnection->parent->recordBlock;
		
		recordBlock(&record, recordInfo, collection, key, metadata);
	}
	else // if (recordBlockType == YapDatabaseCloudKitBlockTypeWithRow)
	{
		__unsafe_unretained YapDatabaseCloudKitRecordWithRowBlock recordBlock =
		  (YapDatabaseCloudKitRecordWithRowBlock)parentConnection->parent->recordBlock;
		
		id object = [databaseTransaction objectForCollectionKey:collectionKey withRowid:rowid];
		
		recordBlock(&record, recordInfo, collection, key, object, metadata);
	}
	
	// Figure if anything changed, and schedule updates to the table(s) accordingly
	
	[self processRecord:record databaseIdentifier:recordInfo.databaseIdentifier
	                            preCalculatedHash:nil
	                                     forRowid:rowid
	                     withPrevMappingTableInfo:mappingTableInfo
	                          prevRecordTableInfo:recordTableInfo
	                                        flags:0];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleTouchObjectForCollectionKey:(YapCollectionKey *)collectionKey withRowid:(int64_t)rowid
{
	// Nothing to do here.
	// "Touch" is generally meant for local operations.
	//
	// We may add an explicit "remote" touch (declared in YapDatabaseCloudKitTransaction.h)
	// in the future if there seems to be a need for it.
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleTouchMetadataForCollectionKey:(YapCollectionKey *)collectionKey withRowid:(int64_t)rowid
{
	// Nothing to do here.
	// "Touch" is generally meant for local operations.
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveObjectForCollectionKey:(YapCollectionKey *)collectionKey withRowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	// Fetch current mappings & record information for the given rowid.
	
	id <YDBCKMappingTableInfo> mappingTableInfo = nil;
	id <YDBCKRecordTableInfo> recordTableInfo = nil;
	
	mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:YES];
	if (mappingTableInfo) {
		recordTableInfo = [self recordTableInfoForHash:mappingTableInfo.current_recordTable_hash cacheResult:YES];
	}
	
	[self processRecord:nil databaseIdentifier:nil
	                         preCalculatedHash:nil
	                                  forRowid:rowid
	                  withPrevMappingTableInfo:mappingTableInfo
	                       prevRecordTableInfo:recordTableInfo
	                                     flags:0];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveObjectsForKeys:(NSArray *)keys inCollection:(NSString *)collection withRowids:(NSArray *)rowids
{
	YDBLogAutoTrace();
	
	// Fetch a dictionary of valid rowids with the format:
	//
	// key = rowid (NSNumber)
	// value = id<YDBCKMappingTableInfo>  (YDBCKCleanMappingTableInfo || YDBCKDirtyMappingTableInfo)
	
	NSDictionary *mappingTableInfoDict = [self mappingTableInfoForRowids:rowids];
	
	NSMutableSet *hashes = [NSMutableSet setWithCapacity:[mappingTableInfoDict count]];
	for (id <YDBCKMappingTableInfo> mappingTableInfo in [mappingTableInfoDict objectEnumerator])
	{
		[hashes addObject:mappingTableInfo.current_recordTable_hash];
	}
	
	NSDictionary *recordTableInfoDict = [self recordTableInfoForHashes:[hashes allObjects]];
	
	[mappingTableInfoDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		__unsafe_unretained NSNumber *rowidNumber = (NSNumber *)key;
		__unsafe_unretained id <YDBCKMappingTableInfo> mappingTableInfo = (id <YDBCKMappingTableInfo>)obj;
		
		int64_t rowid = [rowidNumber longLongValue];
		
		id <YDBCKRecordTableInfo> recordTableInfo =
		  [recordTableInfoDict objectForKey:mappingTableInfo.current_recordTable_hash];
		
		[self processRecord:nil databaseIdentifier:nil
		                         preCalculatedHash:nil
		                                  forRowid:rowid
		                  withPrevMappingTableInfo:mappingTableInfo
		                       prevRecordTableInfo:recordTableInfo
		                                     flags:0];
	}];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveAllObjectsInAllCollections
{
	YDBLogAutoTrace();
	
	[self removeAllMappingTableRows];
	[self removeAllRecordTableRows];
	
	[parentConnection->cleanMappingTableInfoCache removeAllObjects];
	[parentConnection->cleanRecordTableInfoCache removeAllObjects];
	
	[parentConnection->dirtyMappingTableInfoDict removeAllObjects];
	[parentConnection->dirtyRecordTableInfoDict removeAllObjects];
	
	parentConnection->reset = YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Public API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method is used to associate an existing CKRecord with a row in the database.
 * There are two primary use cases for this method.
 *
 * 1. To associate a discovered/pulled CKRecord with a row in the database before you insert it the row.
 *    In particular, for the following situation:
 *
 *    - You're pulling record changes from the server via CKFetchRecordChangesOperation (or similar).
 *    - You discover a record that was inserted by another device.
 *    - You need to add a corresponding row to the database,
 *      but you also need to inform the YapDatabaseCloudKit extension about the existing record,
 *      so it won't bother invoking the recordHandler, or attempting to upload the existing record.
 *    - So you invoke this method FIRST.
 *    - And THEN you insert the corresponding object into the database via the
 *      normal setObject:forKey:inCollection: method (or similar methods).
 *
 * 2. To assist in the migration process when switching to YapDatabaseCloudKit.
 *    In particular, for the following situation:
 *
 *    - You've been handling CloudKit manually (not via YapDatabaseCloudKit).
 *    - And you now want YapDatabaseCloudKit to manage the CKRecord for you.
 *    - So you can invoke this method for an object that already exists in the database,
 *      OR you can invoke this method FIRST, and then insert the new object that you want linked to the record.
 *
 * Thus, this method works as a simple "hand-off" of the CKRecord to the YapDatabaseCloudKit extension.
 *
 * In other words, YapDatbaseCloudKit will write the system fields of the given CKRecord to its internal table,
 * and associate it with the given collection/key tuple.
 *
 * @param record
 *   The CKRecord to associate with the collection/key tuple.
 *
 * @param databaseIdentifer
 *   The identifying string for the CKDatabase.
 *   @see YapDatabaseCloudKitDatabaseIdentifierBlock.
 *
 * @param key
 *   The key of the row to associate the record with.
 *
 * @param collection
 *   The collection of the row to associate the record with.
 *
 * @param shouldUpload
 *   If NO, then the record is simply associated with the collection/key,
 *     and YapDatabaseCloudKit doesn't attempt to push the record to the cloud.
 *   If YES, then the record is associated with the collection/key,
 *     and YapDatabaseCloutKit assumes the given record is dirty and will push the record to the cloud.
 *
 * @return
 *   YES if the record was associated with the given collection/key.
 *   NO if one of the following errors occurred.
 *
 * The following errors will prevent this method from succeeding:
 * - The given record is nil.
 * - The given collection/key is already associated with a different record (so must detach it first).
 *
 * Important: This method only works if within a readWriteTrasaction.
 * Invoking this method from within a read-only transaction will throw an exception.
**/
- (BOOL)attachRecord:(CKRecord *)inRecord
  databaseIdentifier:(NSString *)databaseIdentifier
              forKey:(NSString *)key
        inCollection:(NSString *)collection
  shouldUploadRecord:(BOOL)shouldUploadRecord
{
	YDBLogAutoTrace();
	
	// Proper API usage check
	if (!databaseTransaction->isReadWriteTransaction)
	{
		@throw [self requiresReadWriteTransactionException:NSStringFromSelector(_cmd)];
		return NO;
	}
	
	// Sanity checks
	
	if (inRecord == nil) {
		return NO;
	}
	if (key == nil) {
		return NO;
	}
	
	CKRecord *record = nil;
	if (shouldUploadRecord)
		record = inRecord;
	else
		record = [inRecord sanitizedCopy];
	
	// Check for attachedRecord that hasn't been inserted into the database yet.
	
	int64_t rowid = 0;
	if (![databaseTransaction getRowid:&rowid forKey:key inCollection:collection])
	{
		YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
		
		YDBCKAttachRequest *attachRequest;
		
		attachRequest = [[YDBCKAttachRequest alloc] init];
		attachRequest.record = record;
		attachRequest.databaseIdentifier = databaseIdentifier;
		attachRequest.shouldUploadRecord = shouldUploadRecord;
		
		if (parentConnection->pendingAttachRequests == nil)
			parentConnection->pendingAttachRequests = [[NSMutableDictionary alloc] initWithCapacity:1];
		
		[parentConnection->pendingAttachRequests setObject:attachRequest forKey:collectionKey];
		
		return YES;
	}
	
	// Handle attach (but make sure we're not overwriting an existing association)
	
	NSString *hash = [self hashRecordID:record.recordID databaseIdentifier:databaseIdentifier];
	
	id <YDBCKMappingTableInfo> mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:YES];
	if (mappingTableInfo)
	{
		NSString *currentHash = mappingTableInfo.current_recordTable_hash;
		
		if (currentHash && ![currentHash isEqualToString:hash])
		{
			// The collection/key is already associated with an existing record.
			// You must detach it first.
			//
			// @see detachRecordForKey:inCollection:wasRemoteDeletion:shouldUploadDeletion:
			
			return NO;
		}
	}
	
	id <YDBCKRecordTableInfo> recordTableInfo = [self recordTableInfoForHash:hash cacheResult:YES];
	
	YDBCKProcessRecordBitMask flags = 0;
	if (!shouldUploadRecord) flags |= YDBCK_skipUploadRecord;
	
	[self processRecord:record databaseIdentifier:databaseIdentifier
	                            preCalculatedHash:hash
	                                     forRowid:rowid
	                     withPrevMappingTableInfo:mappingTableInfo
	                          prevRecordTableInfo:recordTableInfo
	                                        flags:flags];
	
	return YES;
}

/**
 * This method is used to unassociate an existing CKRecord with a row in the database.
 * There are three primary use cases for this method.
 *
 * 1. To properly handle CKRecordID's that are reported as deleted from the server.
 *    In particular, for the following situation:
 *
 *    - You're pulling record changes from the server via CKFetchRecordChangesOperation (or similar).
 *    - You discover a recordID that was deleted by another device.
 *    - You need to remove the associated record from the database,
 *      but you also need to inform the YapDatabaseCloudKit extension that it was remotely deleted,
 *      so it won't bother attempting to upload the already deleted recordID.
 *    - So you invoke this method FIRST.
 *    - And THEN you can remove the corresponding object from the database via the
 *      normal removeObjectForKey:inCollection: method (or similar methods) (if needed).
 *
 * 2. To assist in various migrations, such as version migrations.
 *    For example:
 *
 *    - In version 2 of your app, you need to move a few CKRecords into a new zone.
 *    - But you don't want to delete the items from the old zone,
 *      because you need to continue supporting v1.X for awhile.
 *    - So you invoke this method first in order to drop the previous record association(s).
 *    - And then you can attach the new CKRecord(s),
 *      and have YapDatabaseCloudKit upload the new records (to their new zone).
 *
 * 3. To "move" an object from the cloud to "local-only".
 *    For example:
 *
 *    - You're making a Notes app that allows user to stores notes locally, or in the cloud.
 *    - The user moves an existing note from the cloud, to local-only storage.
 *    - This method can be used to delete the item from the cloud without deleting it locally.
 *
 * @param key
 *   The key of the row associated with the record to detach.
 *
 * @param collection
 *   The collection of the row associated with the record to detach.
 *
 * @param wasRemoteDeletion
 *   Did the server notify you of a deleted CKRecordID?
 *   Then make sure you set this parameter to YES.
 *   This allows the extension to properly modify any changeSets that are still queued for upload
 *   so that it can remove potential modifications for this recordID.
 *
 *   Note: If a record was deleted remotely, and the record was associated with MULTIPLE items in the database,
 *   then you should be sure to invoke this method for each attached collection/key.
 *
 * @param shouldUpload
 *   Whether or not the extension should push a deleted CKRecordID to the cloud.
 *   In use case #2 (from the above discussion, concerning migration), you'd pass NO.
 *   In use case #3 (from the above discussion, concerning moving), you'd pass YES.
 *   This parameter is ignored if wasRemoteDeletion is YES (in which it will force shouldUpload to be NO).
 *
 * Important: This method only works if within a readWriteTrasaction.
 * Invoking this method from within a read-only transaction will throw an exception.
 *
 * @see getKey:collection:forRecordID:databaseIdentifier:
**/
- (void)detachRecordForKey:(NSString *)key
              inCollection:(NSString *)collection
         wasRemoteDeletion:(BOOL)wasRemoteDeletion
      shouldUploadDeletion:(BOOL)shouldUploadDeletion
{
	YDBLogAutoTrace();
	
	// Proper API usage check
	if (!databaseTransaction->isReadWriteTransaction)
	{
		@throw [self requiresReadWriteTransactionException:NSStringFromSelector(_cmd)];
		return;
	}
	
	int64_t rowid;
	if (![databaseTransaction getRowid:&rowid forKey:key inCollection:collection])
	{
		YDBLogWarn(@"%@ - No row in database with given collection/key: %@, %@", THIS_METHOD, collection, key);
		return;
	}
	
	id <YDBCKMappingTableInfo> mappingTableInfo = nil;
	id <YDBCKRecordTableInfo> recordTableInfo = nil;
	
	mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:NO];
	recordTableInfo = [self recordTableInfoForHash:mappingTableInfo.current_recordTable_hash cacheResult:NO];
	
	YDBCKProcessRecordBitMask flags = 0;
	if (wasRemoteDeletion) flags |= YDBCK_remoteDeletion;
	if (!shouldUploadDeletion) flags |= YDBCK_skipUploadDeletion;
	
	[self processRecord:nil databaseIdentifier:nil
	                         preCalculatedHash:nil
	                                  forRowid:rowid
	                  withPrevMappingTableInfo:mappingTableInfo
	                       prevRecordTableInfo:recordTableInfo
	                                     flags:flags];
}

/**
 * This method is used to merge a pulled record from the server with what's in the database.
 * In particular, for the following situation:
 *
 * - You're pulling record changes from the server via CKFetchRecordChangesOperation (or similar).
 * - You discover a record that was modified by another device.
 * - You need to properly merge the changes with your own version of the object in the database,
 *   and you also need to inform YapDatabaseCloud extension about the merger
 *   so it can properly handle any changes that were pending a push to the cloud.
 *
 * Thus, you should use this method, which will invoke your mergeBlock with the appropriate parameters.
 *
 * @param remoteRecord
 *   A record that was modified remotely, and discovered via CKFetchRecordChangesOperation (or similar).
 *   This value will be passed as the remoteRecord parameter to the mergeBlock.
 *
 * @param databaseIdentifier
 *   The identifying string for the CKDatabase.
 *   @see YapDatabaseCloudKitDatabaseIdentifierBlock.
 *
 * Important: This method only works if within a readWriteTrasaction.
 * Invoking this method from within a read-only transaction will throw an exception.
**/
- (void)mergeRecord:(CKRecord *)remoteRecord databaseIdentifier:(NSString *)databaseIdentifier
{
	YDBLogAutoTrace();
	
	// Proper API usage check
	if (!databaseTransaction->isReadWriteTransaction)
	{
		@throw [self requiresReadWriteTransactionException:NSStringFromSelector(_cmd)];
		return;
	}
	
	if (remoteRecord == nil)
	{
		YDBLogWarn(@"%@ - Unable to merge a nil record! Did you mean to detach the recordID?", THIS_METHOD);
		return;
	}
	
	CKRecordID *recordID = remoteRecord.recordID;
	NSString *hash = [self hashRecordID:recordID databaseIdentifier:databaseIdentifier];
	
	id <YDBCKRecordTableInfo> recordTableInfo = [self recordTableInfoForHash:hash cacheResult:YES];
	
	BOOL isInRecordTable = YES;
	
	if (recordTableInfo == nil)
	{
		// The given record is not managed by YapDatabseCloudKit.
		isInRecordTable = NO;
	}
	else if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		  (YDBCKDirtyRecordTableInfo *)recordTableInfo;
		
		if ([dirtyRecordTableInfo hasNilRecordOrZeroOwnerCount])
		{
			// The given record is no longer managed by YapDatabaseCloudKit.
			// (scheduled for removal during commit processing)
			isInRecordTable = NO;
		}
	}
	
	if (!isInRecordTable)
	{
		// The given record is not currently managed by YapDatabaseCloudKit.
		// However ... it's possible we still have this record in the queue.
		// For example:
		// - User modified record
		// - Then user deleted/detached record
		// - Then the modification didn't upload to the server due to partial error.
		// - And the user is merging the latest version of the record now.
		//
		// So if the record exists in our queue, we have to update it (one way or another),
		// or we'll be stuck on this changeSet forever.
		
		BOOL hasPendingChangesInQueue =
		  [parentConnection->parent->masterQueue hasChangesForRecordID:recordID
		                                            databaseIdentifier:databaseIdentifier];
		
		if (!hasPendingChangesInQueue)
		{
			return;
		}
	}
	
	// Make sanitized copy of the remoteRecord.
	// Sanitized == copy of the system fields only, without any values.
	
	CKRecord *pendingLocalRecord = [remoteRecord sanitizedCopy];
	
	// And then infuse the pendingLocalRecord with any key/value pairs that are pending upload.
	//
	// First we start with any previous commits (records that are sitting in the queue, awaiting upload to server)
	
	BOOL hasPendingChanges =
	  [parentConnection->parent->masterQueue mergeChangesForRecordID:recordID
	                                              databaseIdentifier:databaseIdentifier
	                                                      intoRecord:pendingLocalRecord];
	
	// And then we check changes from this readWriteTransaction, just in case.
	
	if (isInRecordTable)
	{
		YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		  [parentConnection->dirtyRecordTableInfoDict objectForKey:hash];
		
		if (dirtyRecordTableInfo)
		{
			for (NSString *changedKey in dirtyRecordTableInfo.dirty_record.changedKeys)
			{
				// Remember: nil is a valid value.
				// It indicates removal of the value for the key, which is a valid action.
				
				id value = [dirtyRecordTableInfo.dirty_record objectForKey:changedKey];
				[pendingLocalRecord setObject:value forKey:changedKey];
			}
			
			hasPendingChanges = YES;
		}
	}
	
	// Invoke the mergeBlock on any associated collection/key
	
	__unsafe_unretained YapDatabaseCloudKitMergeBlock mergeBlock = parentConnection->parent->mergeBlock;
	__unsafe_unretained YapDatabaseReadWriteTransaction *rwTransaction =
	  (YapDatabaseReadWriteTransaction *)databaseTransaction;
	
	CKRecord *newLocalRecord = [remoteRecord sanitizedCopy];
	
	if (isInRecordTable)
	{
		NSArray *rowids = [self mappingTableRowidsForRecordTableHash:hash];
		for (NSNumber *rowidNumber in rowids)
		{
			int64_t rowid = [rowidNumber longLongValue];
			YapCollectionKey *ck = [databaseTransaction collectionKeyForRowid:rowid];
			
			if (hasPendingChanges)
				mergeBlock(rwTransaction, ck.collection, ck.key, remoteRecord, pendingLocalRecord, newLocalRecord);
			else
				mergeBlock(rwTransaction, ck.collection, ck.key, remoteRecord, nil, newLocalRecord);
		}
	}
	else if (hasPendingChanges)
	{
		mergeBlock(rwTransaction, nil, nil, remoteRecord, pendingLocalRecord, newLocalRecord);
	}
	
	// Store the results
	
	if (recordTableInfo)
	{
		if ([recordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
			  (YDBCKCleanRecordTableInfo *)recordTableInfo;
			
			CKRecord *baseRecord = [self baseRecordForCleanRecordTableInfo:cleanRecordTableInfo
			                                                      withHash:hash
			                                          excludingChangedKeys:newLocalRecord.changedKeys];
			
			YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = [cleanRecordTableInfo dirtyCopyWithBaseRecord:baseRecord];
			
			[self mergeChangedValuesFromRecord:newLocalRecord intoRecord:dirtyRecordTableInfo.dirty_record];
			
			dirtyRecordTableInfo.remoteMerge = YES;
			
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:hash];
			[parentConnection->dirtyRecordTableInfoDict setObject:dirtyRecordTableInfo forKey:hash];
		}
		else // if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
			  (YDBCKDirtyRecordTableInfo *)recordTableInfo;
			
			[self mergeChangedValuesFromRecord:newLocalRecord intoRecord:dirtyRecordTableInfo.dirty_record];
			
			dirtyRecordTableInfo.remoteMerge = YES;
		}
	}
	else if (hasPendingChanges)
	{
		YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		  [[YDBCKDirtyRecordTableInfo alloc] initWithDatabaseIdentifier:databaseIdentifier
		                                                       recordID:recordID
		                                                     ownerCount:0
		                                                recordKeys_hash:nil];
		
		dirtyRecordTableInfo.dirty_record = newLocalRecord;
		dirtyRecordTableInfo.remoteMerge = YES;
		
		[parentConnection->dirtyRecordTableInfoDict setObject:dirtyRecordTableInfo forKey:hash];
	}
}

/**
 * This method allows you to manually modify a CKRecord.
 * 
 * This is useful for tasks such as migrations, debugging, and various one-off tasks during the development lifecycle.
 * For example, you added a property to some on of your model classes in the database,
 * but you forgot to add the code that creates the corresponding property in the CKRecord.
 * So you might whip up some code that uses this method, and forces that property to get uploaded to the server
 * for all the corresponding model objects that you already updated.
 * 
 * Returns NO if the given recordID/databaseIdentifier is unknown.
 * That is, such a record has not been given to YapDatabaseCloudKit (via the recordHandler),
 * or has not previously been associated with a collection/key,
 * or the record was deleted earlier in this transaction.
 *
 * Important: This method only works if within a readWriteTrasaction.
 * Invoking this method from within a read-only transaction will throw an exception.
**/
- (BOOL)saveRecord:(CKRecord *)record databaseIdentifier:(NSString *)databaseIdentifier
{
	YDBLogAutoTrace();
	
	if (record == nil) return NO;
	
	NSString *hash = [self hashRecordID:record.recordID databaseIdentifier:databaseIdentifier];
	
	id <YDBCKRecordTableInfo> recordTableInfo = [self recordTableInfoForHash:hash cacheResult:YES];
	
	if (recordTableInfo == nil)
	{
		// The given record is not managed by YapDatabseCloudKit.
		return NO;
	}
	
	if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
	{
		__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
		  (YDBCKDirtyRecordTableInfo *)recordTableInfo;
		
		if ([dirtyRecordTableInfo hasNilRecordOrZeroOwnerCount])
		{
			// The given record is no longer managed by YapDatabaseCloudKit.
			// (scheduled for removal during commit processing)
			return NO;
		}
	}
	
	// Store the results (if needed)
	
	if ([record.changedKeys count] > 0)
	{
		if ([recordTableInfo isKindOfClass:[YDBCKCleanRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKCleanRecordTableInfo *cleanRecordTableInfo =
			  (YDBCKCleanRecordTableInfo *)recordTableInfo;
			
			CKRecord *baseRecord = [self baseRecordForCleanRecordTableInfo:cleanRecordTableInfo
			                                                      withHash:hash
			                                          excludingChangedKeys:record.changedKeys];
			
			YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = [cleanRecordTableInfo dirtyCopyWithBaseRecord:baseRecord];
			
			[self mergeChangedValuesFromRecord:record intoRecord:dirtyRecordTableInfo.dirty_record];
			
			[parentConnection->cleanRecordTableInfoCache removeObjectForKey:hash];
			[parentConnection->dirtyRecordTableInfoDict setObject:dirtyRecordTableInfo forKey:hash];
		}
		else // if ([recordTableInfo isKindOfClass:[YDBCKDirtyRecordTableInfo class]])
		{
			__unsafe_unretained YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo =
			  (YDBCKDirtyRecordTableInfo *)recordTableInfo;
			
			[self mergeChangedValuesFromRecord:record intoRecord:dirtyRecordTableInfo.dirty_record];
		}
	}
	
	return YES;
}

/**
 * If the given recordID & databaseIdentifier are associated with a row in the database,
 * then this method will return YES, and set the collectionPtr/keyPtr with the collection/key of the associated row.
 *
 * @param keyPtr (optional)
 *   If non-null, and this method returns YES, then the keyPtr will be set to the associated row's key.
 *
 * @param collectionPtr (optional)
 *   If non-null, and this method returns YES, then the collectionPtr will be set to the associated row's collection.
 *
 * @param recordID
 *   The CKRecordID to look for.
 *
 * @param databaseIdentifier
 *   The identifying string for the CKDatabase.
 *   @see YapDatabaseCloudKitDatabaseIdentifierBlock.
 *
 * @return
 *   YES if the given recordID & databaseIdentifier are associated with a row in the database.
 *   NO otherwise.
 *
 *
 * Note:
 *   It's possible to associate multiple items in the database with a single CKRecord/databaseIdentifier.
 *   This is completely legal, and supported by YapDatabaseCloudKit extension.
 *   However, if you do this keep in mind that this method will only return 1 of the associated items.
 *   Further, which item it returns is not guaranteed, and may change between method invocations.
 *   So, in this particular case, you likely should be using 'collectionKeysForRecordID:databaseIdentifier:'.
**/
- (BOOL)getKey:(NSString **)keyPtr collection:(NSString **)collectionPtr
                                  forRecordID:(CKRecordID *)recordID
                           databaseIdentifier:(NSString *)databaseIdentifier
{
	YDBLogAutoTrace();
	
	if (recordID == nil)
	{
		if (keyPtr) *keyPtr = nil;
		if (collectionPtr) *collectionPtr = nil;
		return NO;
	}
	
	NSString *hash = [self hashRecordID:recordID databaseIdentifier:databaseIdentifier];
	NSArray *rowids = [self mappingTableRowidsForRecordTableHash:hash];
	
	YapCollectionKey *ck = nil;
	if (rowids.count > 0)
	{
		int64_t rowid = [[rowids firstObject] longLongValue];
		ck = [databaseTransaction collectionKeyForRowid:rowid];
	}
	
	if (keyPtr) *keyPtr = ck.key;
	if (collectionPtr) *collectionPtr = ck.collection;
	
	return (ck != nil);
}

/**
 * It's possible to associate multiple items in the database with a single CKRecord/databaseIdentifier.
 * This is completely legal, and supported by YapDatabaseCloudKit extension.
 *
 * This method returns an array of YapCollectionKey objects,
 * each associated with the given recordID/databaseIdentifier.
 *
 * @see YapCollectionKey
**/
- (NSArray *)collectionKeysForRecordID:(CKRecordID *)recordID databaseIdentifier:(NSString *)databaseIdentifier
{
	YDBLogAutoTrace();
	
	if (recordID == nil) {
		return nil;
	}
	
	NSString *hash = [self hashRecordID:recordID databaseIdentifier:databaseIdentifier];
	NSArray *rowids = [self mappingTableRowidsForRecordTableHash:hash];
	
	NSUInteger count = rowids.count;
	if (count == 0) {
		return nil;
	}
	
	NSMutableArray *collectionKeys = [NSMutableArray arrayWithCapacity:count];
	for (NSNumber *rowidNumber in rowids)
	{
		int64_t rowid = [rowidNumber longLongValue];
		
		YapCollectionKey *ck = [databaseTransaction collectionKeyForRowid:rowid];
		if (ck) {
			[collectionKeys addObject:ck];
		}
	}
	
	return collectionKeys;
}

/**
 * If the given key/collection tuple is associated with a record,
 * then this method returns YES, and sets the recordIDPtr & databaseIdentifierPtr accordingly.
 * 
 * @param recordIDPtr (optional)
 *   If non-null, and this method returns YES, then the recordIDPtr will be set to the associated recordID.
 * 
 * @param databaseIdentifierPtr (optional)
 *   If non-null, and this method returns YES, then the databaseIdentifierPtr will be set to the associated value.
 *   Keep in mind that nil is a valid databaseIdentifier,
 *   and is generally used to signify the defaultContainer/privateCloudDatabase.
 *
 * @param key
 *   The key of the row in the database.
 * 
 * @param collection
 *   The collection of the row in the database.
 * 
 * @return
 *   YES if the given collection/key is associated with a CKRecord.
 *   NO otherwise.
**/
- (BOOL)getRecordID:(CKRecordID **)recordIDPtr
 databaseIdentifier:(NSString **)databaseIdentifierPtr
             forKey:(NSString *)key
       inCollection:(NSString *)collection
{
	CKRecordID *recordID = nil;
	NSString *databaseIdentifier = nil;
	
	int64_t rowid = 0;
	if ([databaseTransaction getRowid:&rowid forKey:key inCollection:collection])
	{
		id <YDBCKMappingTableInfo> mappingTableInfo = [self mappingTableInfoForRowid:rowid cacheResult:YES];
		if (mappingTableInfo)
		{
			NSString *hash = mappingTableInfo.current_recordTable_hash;
			
			id <YDBCKRecordTableInfo> recordTableInfo = [self recordTableInfoForHash:hash cacheResult:YES];
			if (recordTableInfo)
			{
				recordID = recordTableInfo.current_record.recordID;
				databaseIdentifier = recordTableInfo.databaseIdentifier;
			}
		}
	}
	
	if (recordIDPtr) *recordIDPtr = recordID;
	if (databaseIdentifierPtr) *databaseIdentifierPtr = databaseIdentifier;
	
	return (recordID != nil);
}

/**
 * Returns a copy of the CKRcord for the given recordID/databaseIdentifier.
 * 
 * Keep in mind that YapDatabaseCloudKit stores ONLY the system fields of a CKRecord.
 * That is, it does NOT store any key/value pairs.
 * It only stores "system fields", which is the internal metadata that CloudKit uses to handle sync state.
 * 
 * So if you invoke this method from within a read-only transaction,
 * then you will receive a "base" CKRecord, which is really only useful for extracting "system field" metadata,
 * such as the 'recordChangeTag'.
 * 
 * If you invoke this method from within a read-write transaction,
 * then you will receive the "base" CKRecord, along with any modifications that have been made to the CKRecord
 * during the current read-write transaction.
 * 
 * Also keep in mind that you are receiving a copy of the record which YapDatabaseCloudKit is using internally.
 * If you intend to manually modify the CKRecord directly,
 * then you need to save those changes back into YapDatabaseCloudKit via 'saveRecord:databaseIdentifier'.
 * 
 * @see saveRecord:databaseIdentifier:
**/
- (CKRecord *)recordForRecordID:(CKRecordID *)recordID databaseIdentifier:(NSString *)databaseIdentifier
{
	YDBLogAutoTrace();
	
	if (recordID == nil) return nil;
	
	NSString *hash = [self hashRecordID:recordID databaseIdentifier:databaseIdentifier];
	
	id <YDBCKRecordTableInfo> recordTableInfo = [self recordTableInfoForHash:hash cacheResult:YES];
	
	CKRecord *record = [recordTableInfo.current_record safeCopy];
	return record;
}

/**
 * Convenience method.
 * Combines the following two methods into a single call:
 * 
 * - getRecordID:databaseIdentifier:forKey:inCollection:
 * - recordForRecordID:databaseIdentifier:
 * 
 * @see recordForRecordID:databaseIdentifier:
**/
- (CKRecord *)recordForKey:(NSString *)key inCollection:(NSString *)collection
{
	YDBLogAutoTrace();
	
	CKRecordID *recordID = nil;
	NSString *databaseIdentifier = nil;
	
	if ([self getRecordID:&recordID databaseIdentifier:&databaseIdentifier forKey:key inCollection:collection])
	{
		return [self recordForRecordID:recordID databaseIdentifier:databaseIdentifier];
	}
	
	return nil;
}

/**
 * High performance lookup method, if you only need to know if YapDatabaseCloudKit has a
 * record for the given recordID/databaseIdentifier.
 *
 * This method is much faster than invoking recordForRecordID:databaseIdentifier:,
 * if you don't actually need the record.
**/
- (BOOL)containsRecordID:(CKRecordID *)recordID databaseIdentifier:(NSString *)databaseIdentifier
{
	YDBLogAutoTrace();
	
	if (recordID == nil) return NO;
	
	NSString *hash = [self hashRecordID:recordID databaseIdentifier:databaseIdentifier];
	
	YDBCKDirtyRecordTableInfo *dirtyRecordTableInfo = nil;
	YDBCKCleanRecordTableInfo *cleanRecordTableInfo = nil;
	
	// Check dirtyRecordTableInfo (modified records)
	
	dirtyRecordTableInfo = [parentConnection->dirtyRecordTableInfoDict objectForKey:hash];
	if (dirtyRecordTableInfo)
	{
		if ([dirtyRecordTableInfo hasNilRecordOrZeroOwnerCount])
			return NO;
		else
			return YES;
	}
	
	// Check cleanRecordTableInfo (cache)
	
	cleanRecordTableInfo = [parentConnection->cleanRecordTableInfoCache objectForKey:hash];
	if (cleanRecordTableInfo)
	{
		if (cleanRecordTableInfo == (id)[NSNull null])
			return NO;
		else
			return YES;
	}
	
	// Fetch from disk
	
	sqlite3_stmt *statement = [parentConnection recordTable_getCountForHashStatement];
	if (statement == NULL) {
		return NO;
	}
	
	// SELECT COUNT(*) AS NumberOfRows FROM "recordTableName" WHERE "hash" = ?;
	
	int col_count = SQLITE_COL_START + 0;
	int bind_hash = SQLITE_BIND_START + 0;
	
	YapDatabaseString _hash; MakeYapDatabaseString(&_hash, hash);
	sqlite3_bind_text(statement, bind_hash, _hash.str, _hash.length, SQLITE_STATIC);
	
	int64_t count = 0;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		count = sqlite3_column_int64(statement, col_count);
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@ - Error executing statement: %d %s", THIS_METHOD,
					status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_hash);
	
	return (count > 0);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Exceptions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSException *)requiresReadWriteTransactionException:(NSString *)methodName
{
	NSString *reason = [NSString stringWithFormat:
	  @"The method [YapDatabaseCloudKitTransaction %@] can only be used within a readWriteTransaction.", methodName];
	
	return [NSException exceptionWithName:@"YapDatabaseCloudKit" reason:reason userInfo:nil];
}

@end