package cl.nndsk.medication

import android.app.Application
import androidx.room.Room
import cl.nndsk.medication.core.*
import cl.nndsk.medication.notifications.Reminders

class MedicationApplication : Application() {
    val database by lazy { Room.databaseBuilder(this, LocalDatabase::class.java, "medication.db").build() }
    val identity by lazy { Identity(SecretStore(this)) }
    val reminders by lazy { Reminders(this, database, identity) }
    val repository by lazy { Repository(identity, Api(identity), database).also { it.onChanged = { reminders.reconcile() } } }
}
