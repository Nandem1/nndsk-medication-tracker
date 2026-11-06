package cl.nndsk.medication.ui.family

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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import java.util.UUID

/** La familia de la persona: quién está, con qué rol, y cómo entrar o salir. */
@Composable internal fun FamilyScreen(model: PatientViewModel, state: AppState, incomingToken: String?) {
    val families = state.own?.families.orEmpty()
    var invite by remember { mutableStateOf<Family?>(null) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        Note("Quienes están en la familia cuidan juntos. Cada paciente se une una vez y ve siempre quién tiene acceso.")
        if (families.isEmpty()) CreateFamily(model, state)
        families.forEach { family -> FamilyCard(model, state, family) { invite = family } }
        JoinFamily(model, state, incomingToken)
        Spacer(Modifier.height(GraphiteTokens.Space.lg))
    }
    invite?.let { family -> InviteSheet(model, family) { invite = null } }
}

@Composable private fun CreateFamily(model: PatientViewModel, state: AppState) {
    var name by remember { mutableStateOf("Mi familia") }
    val operation = remember(name) { UUID.randomUUID().toString() }
    SectionCard("Crea tu familia") {
        Note("Después invita a tus padres como pacientes y a quienes te ayudan a cuidarlos. Basta una invitación por persona.")
        OutlinedTextField(name, { name = it }, label = { Text("Nombre de la familia") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        DoseAction("Crear familia", prominent = true, enabled = !state.busy && !state.offline && name.trim().length in 1..60) { model.run { model.repository.createFamily(name, operation) } }
    }
}

@Composable private fun FamilyCard(model: PatientViewModel, state: AppState, family: Family, invite: () -> Unit) {
    var removing by remember { mutableStateOf<FamilyMember?>(null) }
    val me = family.members.firstOrNull { it.you }
    SectionCard(family.name) {
        Note("${if (family.members.size == 1) "1 persona" else "${family.members.size} personas"} · Tu rol: ${roleLabel(family.role)}")
        MemberGroup("Pacientes", family.members.filter { it.role == "patient" }, family) { removing = it }
        MemberGroup("Quienes cuidan", family.members.filter { it.role != "patient" }, family) { removing = it }
        if (family.role == "admin") DoseAction("Invitar a la familia", prominent = true, enabled = !state.offline) { invite() }
        else Note("Sólo quien administra puede invitar o quitar personas.")
        me?.let { SecondaryAction("Salir de la familia", enabled = !state.busy && !state.offline) { removing = it } }
    }
    removing?.let { member ->
        val self = member.you
        AlertDialog(onDismissRequest = { removing = null },
            title = { Text(if (self) "Salir de ${family.name}" else "Quitar a ${memberName(member)}") },
            text = { Text(when {
                self && member.role == "patient" -> "Nadie de la familia podrá seguir viendo tu información."
                self -> "Dejarás de ver a los pacientes de la familia."
                else -> "Dejará de ver y de ser visto por la familia. Un teléfono sin conexión puede conservar su copia hasta detectarlo."
            }) },
            confirmButton = { TextButton(onClick = { removing = null; model.run { model.repository.removeMember(family.id, member.userId) } }) { Text(if (self) "Salir" else "Quitar") } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Volver") } })
    }
}

@Composable private fun MemberGroup(title: String, members: List<FamilyMember>, family: Family, remove: (FamilyMember) -> Unit) {
    if (members.isEmpty() && title != "Pacientes") return
    Text(title.uppercase(), style = GraphiteTokens.Type.caregiverCaption, color = MedicationTrackerTheme.colors.textMuted)
    if (members.isEmpty()) Note("Todavía no hay pacientes. Invita a quien toma los medicamentos.")
    members.forEach { member -> MemberRow(member, family.role == "admin" && !member.you) { remove(member) } }
}

@Composable internal fun MemberRow(member: FamilyMember, removable: Boolean, remove: () -> Unit = {}) {
    val colors = MedicationTrackerTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.minTouchAndroid).semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        Avatar(member.name, member.userId)
        Column(Modifier.weight(1f)) {
            Text(memberName(member) + if (member.you) " (tú)" else "", style = GraphiteTokens.Type.patientLabel)
            Note(roleLabel(member.role))
        }
        if (isNewMember(member)) StatusChip(Chip("Nuevo", cl.nndsk.medication.R.drawable.ic_taken, colors.takenFg, colors.takenBg))
        if (removable) TextButton(onClick = remove, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text("Quitar") }
    }
}

/** Ingreso con código o enlace. Pegar revisa de inmediato; un enlace abierto llega ya escrito. */
@Composable private fun JoinFamily(model: PatientViewModel, state: AppState, incomingToken: String?) {
    val context = LocalContext.current
    var token by remember { mutableStateOf("") }
    var preview by remember { mutableStateOf<Pair<String, FamilyInvitationPreview>?>(null) }
    var previewBusy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
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
    LaunchedEffect(incomingToken) {
        if (!incomingToken.isNullOrBlank()) { token = incomingToken; preview = null; review(incomingToken) }
    }
    SectionCard("Unirse con un código") {
        val paste = {
            val clip = context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty().trim()
            // Del mensaje completo basta el código: el campo queda corto y legible.
            val pasted = runCatching { invitationToken(clip) }.getOrDefault(clip)
            token = pasted; preview = null; error = null
            if (pasted.isEmpty()) error = "No encontramos un código copiado. Vuelve al mensaje, cópialo e intenta de nuevo." else review(pasted)
        }
        if (preview == null) DoseAction("Pegar código", prominent = true, enabled = !previewBusy, action = paste) else SecondaryAction("Pegar código", enabled = !previewBusy, action = paste)
        OutlinedTextField(token, { token = it; preview = null; error = null }, label = { Text("Código de invitación") }, enabled = !previewBusy, modifier = Modifier.fillMaxWidth())
        if (preview == null) SecondaryAction("Revisar invitación", enabled = token.isNotBlank() && !state.busy && !previewBusy) { review(token.trim()) }
        error?.let { ErrorText(it) }
        preview?.let { (reviewed, invitation) ->
            Text(invitation.familyName, style = GraphiteTokens.Type.patientTitle)
            Text(buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(invitation.inviterName ?: "Alguien") }
                append(" te invita como ")
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(roleLabel(invitation.role)) }
            }, style = GraphiteTokens.Type.patientBody)
            if (invitation.role == "patient") Text("Al unirte, quienes cuidan en esta familia, y quienes se unan después, podrán ver tu agenda y tu inventario. Verás siempre quiénes son y podrás salir cuando quieras.", style = GraphiteTokens.Type.patientBody)
            Note("Quiénes están")
            invitation.members.forEach { MemberRow(it, removable = false) }
            invitation.patientNameHint?.let { InfoRow("Nombre sugerido", it) }
            InfoRow("Vence", formatInstant(invitation.expiresAt))
            DoseAction("Unirme a la familia", prominent = true, enabled = !state.busy) { model.run { model.repository.accept(reviewed); preview = null; token = "" } }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun InviteSheet(model: PatientViewModel, family: Family, dismiss: () -> Unit) {
    val context = LocalContext.current
    var role by remember { mutableStateOf("patient") }
    var hint by remember { mutableStateOf("") }
    var invitation by remember { mutableStateOf<CreatedInvitation?>(null) }
    var busy by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text(if (invitation == null) "Invitar a ${family.name}" else "Invitación lista", style = GraphiteTokens.Type.patientTitle)
            if (invitation == null) {
                SectionTitle("¿Cómo participará?")
                Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
                    familyRoles.keys.forEach { value ->
                        Row(Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.minTouchAndroid).selectable(selected = role == value, role = Role.RadioButton) { role = value },
                            horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm), verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = role == value, onClick = null)
                            Column {
                                Text(roleLabel(value), style = GraphiteTokens.Type.patientLabel)
                                Note(roleDescription(value))
                            }
                        }
                    }
                }
                if (role == "patient") OutlinedTextField(hint, { hint = it }, label = { Text("¿Cómo se llama? (opcional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Note("Vence en 7 días y sirve para una sola persona.")
                DoseAction("Crear invitación", enabled = !busy && hint.trim().length <= 60, prominent = true) {
                    busy = true; error = null
                    model.run { try { invitation = model.repository.invite(family.id, role, hint) }
                    catch (_: Exception) { error = "No se pudo crear la invitación. Reintenta para generar una nueva." }
                    finally { busy = false } }
                }
            } else invitation?.let { created ->
                val message = invitationMessage(created.token, family.name)
                Note("Para configurar un teléfono en persona, abre la cámara del otro teléfono y escanea este código.")
                QrCode(invitationLink(created.token), "QR para unirse a ${family.name}", Modifier.fillMaxWidth(0.7f).align(Alignment.CenterHorizontally))
                DoseAction("Compartir invitación", prominent = true) {
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, message), "Compartir invitación"))
                }
                SecondaryAction("Copiar mensaje") {
                    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Invitación", message))
                    copied = true
                }
                if (copied) Note("Mensaje copiado.")
                SelectionContainer { Text(created.token, fontFamily = FontFamily.Monospace, style = GraphiteTokens.Type.caregiverBody) }
                InfoRow("Vence", formatInstant(created.expiresAt))
                Note("Comparte antes de cerrar: el código sólo se muestra una vez.")
            }
            error?.let { ErrorText(it) }
            SecondaryAction("Cerrar") { dismiss() }
            Spacer(Modifier.height(8.dp))
        }
    }
}
