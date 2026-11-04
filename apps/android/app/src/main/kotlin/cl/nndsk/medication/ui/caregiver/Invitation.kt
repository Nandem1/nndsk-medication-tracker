package cl.nndsk.medication.ui.caregiver

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.theme.GraphiteTokens

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun InviteSheet(model: PatientViewModel, dismiss: () -> Unit) {
    val context = LocalContext.current
    var preset by remember { mutableStateOf("Administrar todo") }
    var hint by remember { mutableStateOf("") }
    var invitation by remember { mutableStateOf<CreatedInvitation?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text("Invitar paciente", style = GraphiteTokens.Type.patientTitle)
            if (invitation == null) {
                OutlinedTextField(hint, { hint = it }, label = { Text("¿Cómo se llama? (opcional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                invitationPresets.forEach { (label, scopes) ->
                    FilterChip(selected = preset == label, onClick = { preset = label }, label = { Text(label) })
                    Note(scopes.joinToString { scopeLabel(it) })
                }
                Note("El paciente revisará estos permisos antes de autorizarte. Vence en 24 horas.")
                DoseAction("Crear invitación", enabled = !busy && hint.trim().length <= 60, prominent = true) {
                    busy = true; error = null
                    model.run { try { invitation = model.repository.createInvitation(invitationPresets.getValue(preset), hint) }
                    catch (_: Exception) { error = "No se pudo crear la invitación. Reintenta para generar una nueva." }
                    finally { busy = false } }
                }
            } else invitation?.let { created ->
                val message = invitationMessage(created.token)
                Text(message)
                InfoRow("Vence", formatInstant(created.expiresAt))
                DoseAction("Compartir invitación", prominent = true) {
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, message), "Compartir invitación"))
                }
                DoseAction("Copiar mensaje") { context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Invitación", message)) }
                Note("Guarda el mensaje antes de cerrar: el código sólo se muestra una vez.")
            }
            error?.let { Text(it) }
            DoseAction("Cerrar") { dismiss() }
        }
    }
}
