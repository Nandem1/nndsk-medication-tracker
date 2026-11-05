package cl.nndsk.medication.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import java.util.UUID

@Composable internal fun ProfileEditor(model: PatientViewModel, snapshot: Snapshot, busy: Boolean, title: String? = "Mi perfil") {
    var name by remember(snapshot.access?.displayName) { mutableStateOf(snapshot.access?.displayName.orEmpty()) }
    val operation = remember(name, snapshot.access?.profileVersion) { UUID.randomUUID().toString() }
    SectionCard(title) {
        if (snapshot.context.actorId == snapshot.context.patientId) InfoRow("Correo", model.repository.identity.email)
        OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("Nombre visible") }, modifier = Modifier.fillMaxWidth())
        val valid = !busy && name.trim().length in 1..60
        val save = { model.run { model.repository.updateProfile(snapshot.context.patientId, name, snapshot.access?.profileVersion ?: 1, operation) }; Unit }
        // Sin título es el paso del onboarding: guardar es lo único por hacer.
        if (title == null) DoseAction("Guardar nombre", prominent = true, enabled = valid, action = save) else SecondaryAction("Guardar nombre", enabled = valid, action = save)
    }
}

@Composable internal fun Onboarding(model: PatientViewModel, state: AppState) {
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        if (state.own?.profile?.profileComplete == false) {
            Text("¿Cómo te llamas?", style = GraphiteTokens.Type.patientTitle)
            Note("Tu familia verá este nombre en la app.")
            state.own?.let { ProfileEditor(model, it, state.busy, null) }
        } else {
            Text("¿Cómo usarás la app?", style = GraphiteTokens.Type.patientTitle)
            Note("Esta elección organiza las pantallas. Los permisos los autoriza cada paciente.")
            DoseAction("Tomo mis medicamentos", prominent = true) { model.run { model.repository.setUse(false) } }
            DoseAction("Cuido a alguien") { model.run { model.repository.setUse(true) } }
        }
        TextButton(onClick = { model.run { model.repository.logout() } }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text("Cerrar sesión") }
    }
}
