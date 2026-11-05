package cl.nndsk.medication.ui.caregiver

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.theme.GraphiteTokens

private fun presetDescription(label: String) = when (label) {
    "Sólo mirar" -> "Ves su agenda, historial e inventario. No cambias nada."
    "Ayudar a registrar" -> "Además, registras y corriges sus tomas."
    else -> "Además, administras sus tratamientos e inventario."
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun InviteSheet(model: PatientViewModel, dismiss: () -> Unit) {
    val context = LocalContext.current
    var preset by remember { mutableStateOf("Administrar todo") }
    var hint by remember { mutableStateOf("") }
    var invitation by remember { mutableStateOf<CreatedInvitation?>(null) }
    var busy by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text(if (invitation == null) "Invitar a alguien" else "Invitación lista", style = GraphiteTokens.Type.patientTitle)
            if (invitation == null) {
                OutlinedTextField(hint, { hint = it }, label = { Text("¿Cómo se llama? (opcional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                SectionTitle("¿Qué podrás hacer?")
                Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
                    invitationPresets.keys.forEach { label ->
                        Row(Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.minTouchAndroid).selectable(selected = preset == label, role = Role.RadioButton) { preset = label },
                            horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm), verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = preset == label, onClick = null)
                            Column {
                                Text(label, style = GraphiteTokens.Type.patientLabel)
                                Note(presetDescription(label))
                            }
                        }
                    }
                }
                Note("La persona revisará estos permisos antes de autorizarte. Vence en 24 horas.")
                DoseAction("Crear invitación", enabled = !busy && hint.trim().length <= 60, prominent = true) {
                    busy = true; error = null
                    model.run { try { invitation = model.repository.createInvitation(invitationPresets.getValue(preset), hint) }
                    catch (_: Exception) { error = "No se pudo crear la invitación. Reintenta para generar una nueva." }
                    finally { busy = false } }
                }
            } else invitation?.let { created ->
                val message = invitationMessage(created.token)
                DoseAction("Compartir invitación", prominent = true) {
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, message), "Compartir invitación"))
                }
                SecondaryAction("Copiar mensaje") {
                    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Invitación", message))
                    copied = true
                }
                if (copied) Note("Mensaje copiado.")
                SectionTitle("Qué sigue")
                listOf("1. Envía el mensaje por WhatsApp u otro medio privado.", "2. La persona abre la app, entra en Ajustes › Acceso de cuidadores y pega el código.", "3. Cuando autorice, aparecerá en Pacientes.")
                    .forEach { Text(it, style = GraphiteTokens.Type.patientBody) }
                SelectionContainer { Text(created.token, fontFamily = FontFamily.Monospace, style = GraphiteTokens.Type.caregiverBody) }
                InfoRow("Vence", formatInstant(created.expiresAt))
                Note("Comparte antes de cerrar: el código sólo se muestra una vez.")
            }
            error?.let { ErrorText(it) }
            SecondaryAction("Cerrar") { dismiss() }
        }
    }
}
