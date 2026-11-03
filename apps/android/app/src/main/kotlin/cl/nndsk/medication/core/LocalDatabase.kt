package cl.nndsk.medication.core

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "snapshots", primaryKeys = ["owner", "patient"])
data class StoredSnapshot(val owner: String, val patient: String, val json: String)

@Entity(tableName = "operations", indices = [Index(value = ["owner", "patient", "dose"], unique = true)])
data class PendingOperation(
    @PrimaryKey val id: String, val owner: String, val patient: String,
    val dose: String, val path: String, val body: String,
    val createdAt: Long, val status: String = "pending",
)

@Dao
interface LocalDao {
    @Query("SELECT * FROM snapshots WHERE owner=:owner AND patient=:patient")
    suspend fun snapshot(owner: String, patient: String): StoredSnapshot?
    @Query("SELECT * FROM snapshots WHERE owner=:owner")
    suspend fun snapshots(owner: String): List<StoredSnapshot>
    @Upsert suspend fun save(snapshot: StoredSnapshot)
    @Query("SELECT * FROM operations WHERE owner=:owner AND patient=:patient ORDER BY createdAt,id")
    suspend fun operations(owner: String, patient: String): List<PendingOperation>
    @Query("SELECT * FROM operations WHERE owner=:owner AND patient=:patient ORDER BY createdAt,id")
    fun observeOperations(owner: String, patient: String): Flow<List<PendingOperation>>
    @Insert(onConflict = OnConflictStrategy.IGNORE) suspend fun enqueue(operation: PendingOperation): Long
    @Query("UPDATE operations SET status=:status WHERE id=:id AND owner=:owner AND patient=:patient")
    suspend fun mark(owner: String, patient: String, id: String, status: String)
    @Query("DELETE FROM operations WHERE id=:id AND owner=:owner AND patient=:patient")
    suspend fun remove(owner: String, patient: String, id: String)
    @Query("DELETE FROM operations") suspend fun clearAllOperations()
    @Query("DELETE FROM snapshots") suspend fun clearAllSnapshots()
    @Query("DELETE FROM operations WHERE owner=:owner") suspend fun clearOperations(owner: String)
    @Query("DELETE FROM snapshots WHERE owner=:owner") suspend fun clearSnapshots(owner: String)
}

@Database(entities = [StoredSnapshot::class, PendingOperation::class], version = 1, exportSchema = true)
abstract class LocalDatabase : RoomDatabase() { abstract fun local(): LocalDao }
