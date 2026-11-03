package cl.nndsk.medication

import android.app.Application
import androidx.room.Room
import cl.nndsk.medication.core.*
import cl.nndsk.medication.notifications.Reminders
import cl.nndsk.medication.notifications.RemotePushRegistration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class MedicationApplication : Application() {
    val backgroundScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val remotePush by lazy { RemotePushRegistration(this, identity, Api(identity)) }
    override fun onCreate() { super.onCreate(); remotePush.initialize() }
    val database by lazy { Room.databaseBuilder(this, LocalDatabase::class.java, "medication.db").build() }
    val identity by lazy { Identity(SecretStore(this)) }
    val reminders by lazy { Reminders(this, database, identity) }
    val repository by lazy { Repository(identity, Api(identity), database).also { it.onChanged = { reminders.reconcile(); remotePush.reconcile() }; it.onSignedIn = { remotePush.signedIn() }; it.onSigningOut = { remotePush.signOut() } } }
}
