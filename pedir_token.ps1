# Ventana para escribir el token personal. Se abre solo la primera vez (o con "npm run token").
# Guarda el token en .env (ACCESS_TOKEN) y sale con código 0 si se pulsa "Guardar", 1 si se cancela.
# El juego de Roblox lo recibe solo del bridge (/handshake): no hay que ponerlo en ningún script.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $here '.env'
$examplePath = Join-Path $here '.env.example'

# Si no hay .env todavía, lo creamos a partir del ejemplo
if (-not (Test-Path $envPath) -and (Test-Path $examplePath)) {
    Copy-Item $examplePath $envPath
}
$envText = if (Test-Path $envPath) { [IO.File]::ReadAllText($envPath, [Text.Encoding]::UTF8) } else { '' }

# Token guardado la última vez (si no es el de ejemplo)
$savedToken = ''
if ($envText -match '(?m)^ACCESS_TOKEN=(.*)$') {
    $savedToken = $matches[1].Trim()
    if ($savedToken -eq 'cambia-esto-por-algo-secreto') { $savedToken = '' }
}

# ---------- Colores (mismo estilo que el panel) ----------
$bg = [Drawing.Color]::FromArgb(17, 17, 22)
$card = [Drawing.Color]::FromArgb(26, 26, 34)
$text = [Drawing.Color]::FromArgb(238, 238, 238)
$muted = [Drawing.Color]::FromArgb(150, 150, 160)
$gold = [Drawing.Color]::FromArgb(255, 200, 70)
$red = [Drawing.Color]::FromArgb(255, 120, 120)

$form = New-Object Windows.Forms.Form
$form.Text = 'Bridge - A la trompa!'
$form.ClientSize = New-Object Drawing.Size(460, 300)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $bg
$form.ForeColor = $text
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.TopMost = $true

$title = New-Object Windows.Forms.Label
$title.Text = '🥊 ¡A LA TROMPA! — Bridge'
$title.Font = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)
$title.ForeColor = $gold
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(20, 16)
$form.Controls.Add($title)

$info = New-Object Windows.Forms.Label
$info.Text = "Escribe tu token personal (o genera uno).`nSolo se pide una vez: Roblox Studio lo recibe solo al darle a Play."
$info.ForeColor = $muted
$info.Size = New-Object Drawing.Size(420, 42)
$info.Location = New-Object Drawing.Point(20, 56)
$form.Controls.Add($info)

$box = New-Object Windows.Forms.TextBox
$box.Text = $savedToken
$box.UseSystemPasswordChar = $true
$box.BackColor = $card
$box.ForeColor = $text
$box.BorderStyle = 'FixedSingle'
$box.Font = New-Object Drawing.Font('Consolas', 12)
$box.Size = New-Object Drawing.Size(320, 30)
$box.Location = New-Object Drawing.Point(20, 108)
$box.MaxLength = 64
$form.Controls.Add($box)

$show = New-Object Windows.Forms.CheckBox
$show.Text = 'Mostrar'
$show.ForeColor = $muted
$show.AutoSize = $true
$show.Location = New-Object Drawing.Point(352, 111)
$show.Add_CheckedChanged({ $box.UseSystemPasswordChar = -not $show.Checked })
$form.Controls.Add($show)

$rules = New-Object Windows.Forms.Label
$rules.Text = 'Entre 6 y 64 caracteres: letras, números, guion ( - ) o guion bajo ( _ ).'
$rules.ForeColor = $muted
$rules.Font = New-Object Drawing.Font('Segoe UI', 8.5)
$rules.AutoSize = $true
$rules.Location = New-Object Drawing.Point(20, 144)
$form.Controls.Add($rules)

$errorLabel = New-Object Windows.Forms.Label
$errorLabel.ForeColor = $red
$errorLabel.Size = New-Object Drawing.Size(420, 22)
$errorLabel.Location = New-Object Drawing.Point(20, 168)
$form.Controls.Add($errorLabel)

function New-Button($label, $x, $w, $back, $fore) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $label
    $b.Size = New-Object Drawing.Size($w, 38)
    $b.Location = New-Object Drawing.Point($x, 200)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $back
    $b.ForeColor = $fore
    $b.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    $form.Controls.Add($b)
    return $b
}

$generate = New-Button '🎲 Generar' 20 120 $card $text
$cancel = New-Button 'Cancelar' 150 110 $card $muted
$start = New-Button '💾 Guardar e iniciar' 270 170 $gold ([Drawing.Color]::FromArgb(40, 30, 5))
$form.AcceptButton = $start
$form.CancelButton = $cancel

$note = New-Object Windows.Forms.Label
$note.Text = 'Se guarda en .env. No lo muestres en el directo. Para cambiarlo: npm run token'
$note.ForeColor = $muted
$note.Font = New-Object Drawing.Font('Segoe UI', 8.5)
$note.AutoSize = $true
$note.Location = New-Object Drawing.Point(20, 256)
$form.Controls.Add($note)

$generate.Add_Click({
    $chars = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 20
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $box.Text = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    $show.Checked = $true
    $errorLabel.Text = ''
})

$cancel.Add_Click({
    $form.DialogResult = 'Cancel'
    $form.Close()
})

$start.Add_Click({
    $token = $box.Text.Trim()
    if ($token -notmatch '^[A-Za-z0-9_-]{6,64}$') {
        $errorLabel.Text = '⚠ Token no válido: revisa la longitud y los caracteres.'
        return
    }
    # Guardar en .env (reemplaza la línea ACCESS_TOKEN o la añade)
    $newText = if ($envText -match '(?m)^ACCESS_TOKEN=') {
        [regex]::Replace($envText, '(?m)^ACCESS_TOKEN=[^\r\n]*', "ACCESS_TOKEN=$token")
    } else {
        $envText.TrimEnd() + "`r`nACCESS_TOKEN=$token`r`n"
    }
    [IO.File]::WriteAllText($envPath, $newText, (New-Object Text.UTF8Encoding $false))
    $form.DialogResult = 'OK'
    $form.Close()
})

$form.Add_Shown({ $box.Focus(); $box.SelectAll() })
$result = $form.ShowDialog()
if ($result -eq 'OK') { exit 0 } else { exit 1 }
