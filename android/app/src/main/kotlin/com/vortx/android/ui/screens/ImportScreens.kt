package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import com.vortx.android.data.CatalogRepository
import com.vortx.android.home.ImportedCatalogs
import com.vortx.android.home.ImportedListCatalog
import com.vortx.android.imports.ImportedListError
import com.vortx.android.imports.ListImport
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/**
 * The three import surfaces reached from [IntegrationsScreen], Android ports of Apple `ListImportView`,
 * `StremioImportView`, and `NuvioImportView`.
 *
 * - [ListImportScreen]: paste a public Letterboxd / MDBList / Trakt list link, resolve it to engine-safe ids
 *   ([ListImport]), preview the resolved titles, and register it as a Home row via the EXISTING
 *   [ImportedCatalogs.register] (validates + persists on the exact key `vortx.catalog.importedLists`).
 *   On-device only; never touches account or library state.
 * - [StremioImportScreen] / [NuvioImportScreen]: a batch add-on installer (paste manifest URLs, one per line)
 *   over the EXISTING [CatalogRepository.installAddon], with per-URL dedupe and a deduped success/failure
 *   summary. Stremio adds a sign-in guidance card; Nuvio omits it (Nuvio has no account to sign into). Ships
 *   NO curated add-on list: the user brings their own manifest URL.
 */

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListImportScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    val colors = VortXTheme.colors

    var urlText by remember { mutableStateOf("") }
    var importing by remember { mutableStateOf(false) }
    var summary by remember { mutableStateOf<String?>(null) }
    var summaryIsError by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<ImportedListCatalog?>(null) }

    fun importList() {
        val url = urlText.trim()
        if (url.isEmpty() || importing) return
        importing = true
        summary = null
        scope.launch {
            val result = ListImport.importList(context, url)
            importing = false
            result.onSuccess { catalog ->
                val registered = ImportedCatalogs.shared(context).register(catalog)
                preview = catalog
                summaryIsError = !registered
                summary = if (registered) {
                    "Imported \"${catalog.title}\"."
                } else {
                    "That list could not be saved. Make sure it has titles and try again."
                }
                if (registered) urlText = ""
            }.onFailure { error ->
                preview = null
                summaryIsError = true
                summary = (error as? ImportedListError)?.message
                    ?: "Could not import that list. Check the URL and your connection."
            }
        }
    }

    ImportScaffold(title = "Import a list", onBack = onBack, modifier = modifier) {
        SurfaceCard(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(VortXTheme.spacing.md),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                Text("Paste a public list link", style = VortXTheme.type.cardTitle)
                Text(
                    "Letterboxd, MDBList, or Trakt. The list must be public. It becomes a Home row you can " +
                        "browse; it never changes your account or library.",
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )
                OutlinedTextField(
                    value = urlText,
                    onValueChange = { urlText = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("https://letterboxd.com/…/list/…") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Done,
                        autoCorrectEnabled = false,
                        capitalization = KeyboardCapitalization.None,
                    ),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.accent,
                        cursorColor = colors.accent,
                    ),
                )
                PrimaryButton(
                    text = if (importing) "Importing…" else "Import list",
                    onClick = { importList() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !importing && urlText.isNotBlank(),
                    loading = importing,
                )
                summary?.let {
                    Text(
                        it,
                        style = VortXTheme.type.label.copy(
                            color = if (summaryIsError) colors.danger else colors.textSecondary,
                        ),
                    )
                }
            }
        }

        preview?.takeIf { it.items.isNotEmpty() }?.let { catalog ->
            SurfaceCard(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(VortXTheme.spacing.md),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    Text(catalog.title, style = VortXTheme.type.cardTitle)
                    Text(
                        "${catalog.items.size} title${if (catalog.items.size == 1) "" else "s"} added as a Home row.",
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                    )
                    catalog.items.take(12).forEach { item ->
                        Text(
                            item.name,
                            style = VortXTheme.type.body.copy(color = colors.textSecondary),
                            maxLines = 1,
                        )
                    }
                    if (catalog.items.size > 12) {
                        Text(
                            "and ${catalog.items.size - 12} more",
                            style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun StremioImportScreen(repo: CatalogRepository, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BatchAddonImportScreen(
        title = "Import from Stremio",
        repo = repo,
        onBack = onBack,
        modifier = modifier,
        signInCard = {
            val colors = VortXTheme.colors
            SurfaceCard(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(VortXTheme.spacing.md),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    Text("Already use Stremio?", style = VortXTheme.type.cardTitle)
                    Text(
                        "Open Stremio under Settings and sign in with your Stremio account. VortX runs on the " +
                            "same engine, so your add-ons, library, and Continue Watching come across " +
                            "automatically, and stay in sync across your devices. Nothing to export or copy by " +
                            "hand.",
                        style = VortXTheme.type.body.copy(color = colors.textSecondary),
                    )
                }
            }
        },
        introTitle = "Add several add-ons at once",
    )
}

@Composable
fun NuvioImportScreen(repo: CatalogRepository, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BatchAddonImportScreen(
        title = "Import from Nuvio",
        repo = repo,
        onBack = onBack,
        modifier = modifier,
        signInCard = {
            val colors = VortXTheme.colors
            SurfaceCard(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(VortXTheme.spacing.md),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    Text("No account to sign into", style = VortXTheme.type.cardTitle)
                    Text(
                        "Nuvio plays through Stremio-compatible add-ons. Paste the add-on link you use in Nuvio " +
                            "to bring its catalogs and streams into VortX. VortX keeps its own account and " +
                            "add-on list.",
                        style = VortXTheme.type.body.copy(color = colors.textSecondary),
                    )
                }
            }
        },
        introTitle = "Add your Nuvio add-ons",
    )
}

/**
 * Shared batch add-on installer behind [StremioImportScreen] and [NuvioImportScreen]: an optional guidance
 * card, then a multi-line paste field that installs every manifest URL through [CatalogRepository.installAddon]
 * (the same path the Add-ons screen uses: normalization + `manifest.json` suffixing + already-installed
 * dedupe), with per-URL input dedupe and a deduped success/failure summary. Mirrors Apple
 * `StremioImportView.installAll` / `NuvioImportView.installAll`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BatchAddonImportScreen(
    title: String,
    repo: CatalogRepository,
    onBack: () -> Unit,
    introTitle: String,
    modifier: Modifier = Modifier,
    signInCard: (@Composable () -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val colors = VortXTheme.colors

    var urlsText by remember { mutableStateOf("") }
    var installing by remember { mutableStateOf(false) }
    var summary by remember { mutableStateOf<String?>(null) }
    var summaryIsError by remember { mutableStateOf(false) }

    fun trimmedUrls(): List<String> {
        val seen = HashSet<String>()
        return urlsText.split("\n")
            .map { it.trim() }
            .filter { it.isNotEmpty() && seen.add(it) }
    }

    fun installAll() {
        val urls = trimmedUrls()
        if (urls.isEmpty() || installing) return
        installing = true
        summary = null
        scope.launch {
            var installed = 0
            val failures = ArrayList<String>()
            for (url in urls) {
                val result = repo.installAddon(url)
                if (result.isFailure) {
                    failures.add(result.exceptionOrNull()?.message ?: "Could not add this add-on.")
                } else {
                    installed += 1
                }
            }
            installing = false
            summaryIsError = installed == 0 && failures.isNotEmpty()
            val plural = if (installed == 1) "" else "s"
            val message = StringBuilder("Installed $installed add-on$plural.")
            if (failures.isNotEmpty()) {
                val reasons = failures.toSet().joinToString(" ")
                message.append(" ${failures.size} could not be added: $reasons")
            }
            summary = message.toString()
            if (failures.isEmpty()) urlsText = ""
        }
    }

    val installLabel = when {
        installing -> "Installing…"
        trimmedUrls().size == 1 -> "Install add-on"
        else -> "Install all add-ons"
    }

    ImportScaffold(title = title, onBack = onBack, modifier = modifier) {
        signInCard?.invoke()
        SurfaceCard(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(VortXTheme.spacing.md),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                Text(introTitle, style = VortXTheme.type.cardTitle)
                Text(
                    "Paste add-on manifest URLs, one per line, then install them all in one step.",
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )
                OutlinedTextField(
                    value = urlsText,
                    onValueChange = { urlsText = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("https://…/manifest.json") },
                    singleLine = false,
                    minLines = 3,
                    maxLines = 10,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        autoCorrectEnabled = false,
                        capitalization = KeyboardCapitalization.None,
                    ),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.accent,
                        cursorColor = colors.accent,
                    ),
                )
                PrimaryButton(
                    text = installLabel,
                    onClick = { installAll() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !installing && trimmedUrls().isNotEmpty(),
                    loading = installing,
                )
                summary?.let {
                    Text(
                        it,
                        style = VortXTheme.type.label.copy(
                            color = if (summaryIsError) colors.danger else colors.textSecondary,
                        ),
                    )
                }
            }
        }
    }
}

/** The shared scrollable, top-bar-with-back scaffold every import screen uses. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ImportScaffold(
    title: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(padding)
                .padding(VortXTheme.spacing.edge)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            content()
        }
    }
}
