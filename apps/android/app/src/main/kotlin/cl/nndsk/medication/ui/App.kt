package cl.nndsk.medication.ui

import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import java.time.*
import cl.nndsk.medication.ui.account.Login
import cl.nndsk.medication.ui.today.Today
import cl.nndsk.medication.ui.today.History
import cl.nndsk.medication.ui.detail.DoseDetail
import cl.nndsk.medication.ui.settings.PatientSettings
import cl.nndsk.medication.ui.components.StatusBanner

@Serializable data class Tab(val name: String) : NavKey
@Serializable data class Detail(val id: String) : NavKey
private val tabs = listOf("Hoy" to R.drawable.ic_today, "Historial" to R.drawable.ic_history, "Ajustes" to R.drawable.ic_settings)
@Composable
fun PatientApp(model: PatientViewModel, incoming: StateFlow<Uri?>) {
    val state by model.state.collectAsStateWithLifecycle()
    val requested by incoming.collectAsStateWithLifecycle()
    val stack = rememberNavBackStack(Tab("Hoy"))
    var confirmClearLocal by remember { mutableStateOf(false) }
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) { while (true) { now = Instant.now(); delay(30_000) } }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { model.run { model.repository.sync() } }
    LaunchedEffect(state.session) {
        if (state.session == Session.SignedOut) { stack.clear(); stack.add(Tab("Hoy")) }
    }
    LaunchedEffect(requested, state.snapshot?.context) {
        val parts = requested?.pathSegments.orEmpty()
        val c = state.snapshot?.context
        if (parts.size == 3 && c != null && parts[0] == c.ownerUid && parts[1] == c.patientId && state.snapshot?.doses?.any { it.id == parts[2] } == true) {
            stack.clear(); stack.add(Tab("Hoy")); stack.add(Detail(parts[2]))
        }
    }
    Scaffold(topBar = {
        if (state.session == Session.Active) PatientTopBar(stack.lastOrNull(), state.busy, onBack = { if (stack.size > 1) stack.removeLastOrNull() }) { model.run { model.repository.sync() } }
    }, bottomBar = {
        if (state.session == Session.Active) NavigationBar {
            tabs.forEach { (name, icon) -> NavigationBarItem(selected = stack.lastOrNull { it is Tab } == Tab(name), onClick = { stack.clear(); stack.add(Tab(name)) },
                icon = { Icon(painterResource(icon), contentDescription = null) }, label = { Text(name) }) }
        }
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp)) {
            if (state.session != Session.Active) Text("Mis tomas", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(vertical = 12.dp))
            // Reserva su alto para que la pantalla no salte al sincronizar.
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth()) else Spacer(Modifier.height(4.dp))
            Spacer(Modifier.height(GraphiteTokens.Space.sm))
            StatusBanner(state)
            if (state.session != Session.Active) {
                Login(state.busy, state.session == Session.Expired) { email, password -> model.run { model.repository.login(email, password) } }
                TextButton(enabled = !state.busy, onClick = { confirmClearLocal = true }) { Text("Cerrar sesión y borrar datos locales") }
            } else {
                NavDisplay(backStack = stack, onBack = { if (stack.size > 1) stack.removeLastOrNull() }, modifier = Modifier.weight(1f), entryProvider = entryProvider {
                    entry<Tab> { tab -> when (tab.name) {
                        "Hoy" -> Today(model, state, now) { stack.add(Detail(it)) }
                        "Historial" -> History(state, now) { stack.add(Detail(it)) }
                        else -> PatientSettings(model, state) { stack.add(Detail(it)) }
                    } }
                    entry<Detail> { detail -> DoseDetail(model, state, detail.id) }
                })
            }
        }
    }
    if (confirmClearLocal) AlertDialog(onDismissRequest = { confirmClearLocal = false }, title = { Text("Borrar datos locales") },
        text = { Text("Se borrarán los datos de este dispositivo y todas las declaraciones pendientes de sincronizar, aunque no se puedan mostrar en esta pantalla. No se enviarán con otra cuenta.") },
        confirmButton = { TextButton(onClick = { confirmClearLocal = false; model.run { model.repository.logout() } }) { Text("Cerrar y borrar") } },
        dismissButton = { TextButton(onClick = { confirmClearLocal = false }) { Text("Volver") } })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun PatientTopBar(current: NavKey?, busy: Boolean, onBack: () -> Unit, sync: () -> Unit) {
    val colors = MedicationTrackerTheme.colors
    val detail = current is Detail
    TopAppBar(
        title = {
            Text(if (detail) "Detalle de la toma" else (current as? Tab)?.name.orEmpty(), maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = if (detail) GraphiteTokens.Type.patientLabel else GraphiteTokens.Type.patientTitle)
        },
        navigationIcon = {
            if (detail) IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_back), contentDescription = "Volver") }
        },
        actions = {
            if (!detail) TextButton(enabled = !busy, onClick = sync, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text("Sincronizar") }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.bg, scrolledContainerColor = colors.bg, titleContentColor = colors.text, navigationIconContentColor = colors.text),
    )
}
