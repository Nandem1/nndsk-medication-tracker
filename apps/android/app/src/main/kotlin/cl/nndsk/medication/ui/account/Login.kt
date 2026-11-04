package cl.nndsk.medication.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.DoseAction

@Composable internal fun Login(busy: Boolean, expired: Boolean, submit: (String, String) -> Unit) {
    var email by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (expired) "Renueva tu sesión con la misma cuenta" else "Inicia sesión")
        OutlinedTextField(email, { email = it }, label = { Text("Correo") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(password, { password = it }, label = { Text("Contraseña") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
        DoseAction("Entrar", prominent = true, enabled = !busy && email.isNotBlank() && password.isNotEmpty()) { submit(email, password); password = "" }
        Text("Cada persona usa su propia cuenta. Los registros son declaraciones y no demuestran ingestión.")
    }
}
