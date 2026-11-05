package cl.nndsk.medication.ui.account

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.DoseAction
import cl.nndsk.medication.ui.components.Note
import cl.nndsk.medication.ui.theme.GraphiteTokens

@Composable internal fun Login(busy: Boolean, expired: Boolean, reset: (String) -> Unit, submit: (String, String, Boolean) -> Unit) {
    var register by remember { mutableStateOf(false) }
    var recover by remember { mutableStateOf(false) }
    var email by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (expired) "Renueva tu sesión con la misma cuenta" else if (recover) "Recuperar contraseña" else if (register) "Crear cuenta" else "Inicia sesión", style = GraphiteTokens.Type.patientLabel)
        OutlinedTextField(email, { email = it }, label = { Text("Correo") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, autoCorrectEnabled = false, imeAction = if (recover) ImeAction.Done else ImeAction.Next), modifier = Modifier.fillMaxWidth())
        if (!recover) OutlinedTextField(password, { password = it }, label = { Text("Contraseña") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = ImeAction.Done),
            visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
            trailingIcon = { TextButton(onClick = { showPassword = !showPassword }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(if (showPassword) "Ocultar" else "Mostrar") } }, modifier = Modifier.fillMaxWidth())
        if (register) Note("Usa al menos 8 caracteres.")
        DoseAction(if (recover) "Enviar instrucciones" else if (register) "Crear cuenta" else "Entrar", prominent = true,
            enabled = !busy && email.isNotBlank() && (recover || if (register) password.length >= 8 else password.isNotEmpty())) {
            if (recover) reset(email) else submit(email, password, register)
            password = ""
        }
        if (!expired) TextButton(onClick = { register = !register; recover = false }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(if (register) "Ya tengo cuenta" else "Crear una cuenta") }
        TextButton(onClick = { recover = !recover; register = false }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(if (recover) "Volver a entrar" else "¿Olvidaste tu contraseña?") }
        Note("Cada persona usa su propia cuenta. Los registros son declaraciones y no demuestran ingestión.")
    }
}
