package cl.nndsk.medication.ui.account

import android.content.Context
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.ApiFailure
import cl.nndsk.medication.ui.components.*
import java.io.File
import java.util.UUID

internal const val deleteAccountConsequences = "Se borrarán tus tomas, tratamientos, inventario y accesos, y tus cuidadores dejarán de verte. Si compartes inventario, el saldo se queda con quienes permanecen. Lo que registraste en la historia de otra persona se conserva sin tu nombre. Las copias de seguridad pueden conservar datos hasta que venzan. No se puede deshacer."

private fun exportsDirectory(context: Context) = File(context.cacheDir, "exports")
internal fun clearExports(context: Context) { exportsDirectory(context).deleteRecursively() }
internal fun writeExport(context: Context, content: String): File {
    clearExports(context)
    return File(exportsDirectory(context).apply { mkdirs() }, "mis-datos.json").apply { writeText(content) }
}

@Composable internal fun AccountActions(model: PatientViewModel, disabled: Boolean) {
    val context = LocalContext.current
    var deleting by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val share = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { clearExports(context) }
    LaunchedEffect(Unit) { clearExports(context) }
    SectionCard("Tus datos") {
        Note("El archivo contiene tus datos de salud. Compártelo sólo con quien corresponda.")
        DoseAction("Descargar mis datos", enabled = !disabled) { model.run {
            try {
                val file = writeExport(context, model.repository.exportAccount())
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.exports", file)
                val send = Intent(Intent.ACTION_SEND).setType("application/json").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                share.launch(Intent.createChooser(send, "Descargar mis datos"))
                message = null
            } catch (_: ApiFailure) { message = "No se pudieron preparar tus datos. Intenta nuevamente." }
            catch (_: java.io.IOException) { message = "No hay conexión. Intenta nuevamente cuando vuelva internet." }
        } }
        DoseAction("Eliminar mi cuenta", enabled = !disabled) { deleting = true }
        if (disabled) Note("Conéctate para descargar tus datos o eliminar tu cuenta.")
        message?.let { Note(it) }
    }
    if (deleting) DeleteAccountDialog(model) { deleting = false }
}

@Composable private fun DeleteAccountDialog(model: PatientViewModel, dismiss: () -> Unit) {
    var typed by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val operation = remember { UUID.randomUUID().toString() }
    AlertDialog(onDismissRequest = { if (!working) dismiss() }, title = { Text("Eliminar mi cuenta") },
        text = { androidx.compose.foundation.layout.Column {
            Text(deleteAccountConsequences)
            OutlinedTextField(typed, { typed = it }, singleLine = true, label = { Text("Escribe BORRAR") }, modifier = Modifier.fillMaxWidth())
            error?.let { Note(it) }
        } },
        confirmButton = { TextButton(enabled = typed == "BORRAR" && !working, onClick = { working = true; model.run {
            try {
                // Con éxito, cerrar sesión ya limpió este teléfono y la pantalla desaparece.
                if (!model.repository.deleteAccount(operation)) error = "Tus datos se borraron, pero no pudimos cerrar tu acceso. Intenta nuevamente."
            } catch (_: ApiFailure) { error = "No se pudo eliminar la cuenta. Intenta nuevamente." }
            catch (_: java.io.IOException) { error = "No hay conexión. No se confirmó la eliminación; intenta nuevamente." }
            working = false
        } }) { Text("Eliminar definitivamente") } },
        dismissButton = { TextButton(enabled = !working, onClick = dismiss) { Text("Volver") } })
}
