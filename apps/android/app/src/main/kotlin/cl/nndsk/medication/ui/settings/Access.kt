package cl.nndsk.medication.ui.settings

import android.content.ClipboardManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.theme.GraphiteTokens

/** Quién ve los datos del paciente y cómo autorizar a alguien nuevo. Cada persona decide por sí misma. */
@Composable internal fun CaregiverAccess(model: PatientViewModel, state: AppState) {
    val context = LocalContext.current
    var token by remember { mutableStateOf("") }; var preview by remember { mutableStateOf<Pair<String, Invitation>?>(null) }
    var previewBusy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }; var revoke by remember { mutableStateOf<Link?>(null) }
    val review: (String) -> Unit = { requested ->
        previewBusy = true
        model.run {
            try {
                val result = model.repository.preview(requested)
                if (token.trim() == requested) { preview = requested to result; error = null }
            } catch (_: Exception) { error = "No se pudo revisar la invitación. Comprueba el código y la conexión." }
            finally { previewBusy = false }
        }
    }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        Note("Tú autorizas el acceso y puedes quitarlo. Un teléfono sin conexión puede conservar su copia hasta volver a conectarse.")
        SectionCard("Aceptar una invitación") {
            val paste = {
                val pasted = context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty().trim()
                token = pasted; preview = null; error = null
                if (pasted.isEmpty()) error = "No encontramos un código copiado. Vuelve al mensaje, cópialo e intenta de nuevo." else review(pasted)
            }
            // Revisada la invitación, la acción principal pasa a ser autorizar.
            if (preview == null) DoseAction("Pegar código", prominent = true, enabled = !previewBusy, action = paste) else SecondaryAction("Pegar código", enabled = !previewBusy, action = paste)
            OutlinedTextField(token, { token = it; preview = null; error = null }, label = { Text("Código de invitación") }, enabled = !previewBusy, modifier = Modifier.fillMaxWidth())
            if (preview == null) SecondaryAction("Revisar invitación", enabled = token.isNotBlank() && !state.busy && !previewBusy) { review(token.trim()) }
            error?.let { ErrorText(it) }
            preview?.let { (reviewedToken, invitation) ->
                Text(buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(invitation.caregiverName ?: "Cuidador sin nombre") }
                    append(" podrá:")
                }, style = GraphiteTokens.Type.patientBody)
                ScopeList(invitation.scopes)
                invitation.patientNameHint?.let { InfoRow("Nombre sugerido", it) }
                InfoRow("Vence", formatInstant(invitation.expiresAt))
                DoseAction("Autorizar estos permisos", prominent = true, enabled = !state.busy) { model.run { model.repository.accept(reviewedToken); preview = null; token = "" } }
            }
        }
        SectionCard("Cuidadores con acceso") {
            if (state.own?.links.isNullOrEmpty()) Note("Ningún cuidador tiene acceso.")
            state.own?.links.orEmpty().forEach { link ->
                Text(link.caregiverName ?: "Cuidador sin nombre", style = GraphiteTokens.Type.patientLabel)
                ScopeList(link.scopes)
                SecondaryAction("Quitar acceso", enabled = !state.busy) { revoke = link }
            }
        }
        Spacer(Modifier.height(GraphiteTokens.Space.lg))
    }
    revoke?.let { link -> AlertDialog(onDismissRequest = { revoke = null }, title = { Text("Quitar acceso") },
        text = { Text("${link.caregiverName ?: "El cuidador"} dejará de tener acceso al servidor. Un teléfono sin conexión puede conservar su copia hasta detectarlo.") },
        confirmButton = { TextButton(onClick = { revoke = null; model.run { model.repository.revoke(link.id) } }) { Text("Quitar acceso") } },
        dismissButton = { TextButton(onClick = { revoke = null }) { Text("Volver") } }) }
}
