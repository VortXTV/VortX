package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.vortx.android.usenet.UsenetProviderRead
import com.vortx.android.usenet.UsenetProviderServer
import com.vortx.android.usenet.UsenetProviderStore

/**
 * Reusable phone settings content for encrypted saved NNTP servers. It deliberately takes a constructed
 * [UsenetProviderStore] and an [onBack] callback: navigation remains owned by the app settings roots.
 * Only the redacted endpoint summary is rendered. Editing with a blank username/password preserves it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun UsenetServersSettingsScreen(
    store: UsenetProviderStore,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var servers by remember { mutableStateOf<List<UsenetProviderServer>>(emptyList()) }
    var revision by remember { mutableLongStateOf(0L) }
    var message by remember { mutableStateOf<String?>(null) }
    var editingId by remember { mutableStateOf<String?>(null) }
    var name by remember { mutableStateOf("") }
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("563") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var connections by remember { mutableStateOf("4") }

    fun refresh(clearMessage: Boolean = true) {
        when (val current = store.snapshot()) {
            is UsenetProviderRead.Available -> {
                servers = current.servers.servers
                revision = current.revision
                if (clearMessage) message = null
            }
            is UsenetProviderRead.Missing -> {
                servers = emptyList()
                revision = current.revision
                if (clearMessage) message = null
            }
            is UsenetProviderRead.UnavailableOrCorrupt -> {
                servers = emptyList()
                revision = current.revision
                message = "Saved Usenet settings could not be read. Nothing was changed."
            }
        }
    }
    fun clearEditor() {
        editingId = null; name = ""; host = ""; port = "563"; username = ""; password = ""; connections = "4"
    }
    fun persist(next: List<UsenetProviderServer>) {
        if (store.saveServers(next, revision)) {
            clearEditor(); refresh()
        } else {
            message = "Could not safely save Usenet servers. Refresh and try again."
            refresh(clearMessage = false)
        }
    }
    fun edit(server: UsenetProviderServer) {
        editingId = server.id
        name = server.name; host = server.host; port = server.port.toString(); connections = server.maxConnections.toString()
        // Do not re-render either credential. Blank retains the encrypted value on save.
        username = ""; password = ""
        message = null
    }
    fun saveEditor() {
        val existing = servers.firstOrNull { it.id == editingId }
        val candidate = UsenetProviderServer(
            id = existing?.id ?: java.util.UUID.randomUUID().toString(),
            name = name.trim(), host = host.trim(), port = port.toIntOrNull() ?: 0,
            username = username.ifBlank { existing?.username.orEmpty() },
            password = password.ifBlank { existing?.password.orEmpty() },
            maxConnections = connections.toIntOrNull() ?: 0,
            useSSL = true,
            enabled = existing?.enabled ?: true,
        )
        if (!candidate.isValid) {
            message = if (existing == null && (username.isBlank() || password.isBlank())) {
                "A new server needs a username and password."
            } else {
                "Enter a name, a valid host, port, and 1–100 connections. TLS is required."
            }
            return
        }
        persist(if (existing == null) servers + candidate else servers.map { if (it.id == existing.id) candidate else it })
    }

    LaunchedEffect(store) { refresh() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Usenet servers") },
                navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Servers are tried from top to bottom. TLS credentials stay encrypted on this device and are never displayed.")
            message?.let { Text(it) }
            servers.forEachIndexed { index, server ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(server.redactedSummary)
                        Text("Priority ${index + 1}")
                    }
                    Switch(checked = server.enabled, onCheckedChange = { enabled ->
                        persist(servers.map { if (it.id == server.id) it.copy(enabled = enabled) else it })
                    })
                    TextButton(onClick = { edit(server) }) { Text("Edit") }
                    TextButton(enabled = index > 0, onClick = {
                        persist(servers.toMutableList().also { list -> val moved = list.removeAt(index); list.add(index - 1, moved) })
                    }) { Text("Up") }
                    TextButton(enabled = index < servers.lastIndex, onClick = {
                        persist(servers.toMutableList().also { list -> val moved = list.removeAt(index); list.add(index + 1, moved) })
                    }) { Text("Down") }
                    TextButton(onClick = { persist(servers.filterNot { it.id == server.id }) }) { Text("Delete") }
                }
            }
            Text(if (editingId == null) "Add server" else "Edit server")
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(host, { host = it }, label = { Text("Host") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(port, { port = it }, label = { Text("Port") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(username, { username = it }, label = { Text(if (editingId == null) "Username" else "Username (blank keeps saved)") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(password, { password = it }, label = { Text(if (editingId == null) "Password" else "Password (blank keeps saved)") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(connections, { connections = it }, label = { Text("Connections") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth())
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = ::saveEditor) { Text(if (editingId == null) "Add server" else "Save changes") }
                if (editingId != null) TextButton(onClick = ::clearEditor) { Text("Cancel") }
            }
        }
    }
}
