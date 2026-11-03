package cl.nndsk.medication

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.net.ConnectivityManager
import android.net.Network
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import cl.nndsk.medication.ui.PatientApp
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

class PatientViewModel(application: Application) : AndroidViewModel(application) {
    val app = application as MedicationApplication
    val repository = app.repository
    val state = repository.state
    private val connectivity = application.getSystemService(ConnectivityManager::class.java)
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { this@PatientViewModel.run { repository.sync() } }
    }
    init {
        viewModelScope.launch { repository.restore() }
        connectivity.registerDefaultNetworkCallback(networkCallback)
    }
    override fun onCleared() { connectivity.unregisterNetworkCallback(networkCallback); super.onCleared() }
    fun run(action: suspend () -> Unit) { viewModelScope.launch { action() } }
}

class MainActivity : ComponentActivity() {
    private val incoming = MutableStateFlow<Uri?>(null)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incoming.value = intent.data
        enableEdgeToEdge()
        setContent {
            val model: PatientViewModel = viewModel()
            MedicationTrackerTheme { PatientApp(model, incoming) }
        }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); incoming.value = intent.data }
}
