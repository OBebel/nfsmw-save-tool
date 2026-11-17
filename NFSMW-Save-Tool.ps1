#Requires -Version 5.1
<#
================================================================================
  NFSMW SAVE TOOL - janela
  Renomeia o perfil do Need for Speed: Most Wanted (2005) sem corromper.

  Nao precisa instalar nada. Nao precisa de Python. E so abrir.

  POR QUE O JOGO REJEITA UM SAVE EDITADO A MAO:
  o nome do jogador fica DENTRO do arquivo, e o save termina com um MD5 do
  proprio corpo:

      MD5( bytes[0x34 : tamanho-16] )  ==  os ultimos 16 bytes

  Mudou um byte, o hash para de bater e o jogo recusa. Recalculando o hash,
  a mesma edicao passa. E so isso.
================================================================================
#>
param([switch] $Conferir,     # so diz se o Windows deixa rodar (as bancadas usam)
      [switch] $Abrir)        # o ABRIR.bat: confere e, se pode, abre o programa SEM console nenhum

# o ABRIR.bat chama com -Abrir: confere se o Windows deixa rodar e, se deixa, abre o programa.
# Nada de metodo .NET antes da conferencia: no modo restrito eles sao barrados antes de chegar na frase
if ($Conferir -or $Abrir) {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Host 'The Windows on this PC runs PowerShell in restricted mode (ConstrainedLanguage), and this program needs the full mode.'
        exit 3
    }
    if ($Abrir) {
        # Sem console: no Windows 11 com o Terminal como padrao, "-WindowStyle Hidden" nao esconde a
        # janela (microsoft/terminal#12464) - e fechar essa janela fecharia o programa junto.
        try {
            $si = New-Object System.Diagnostics.ProcessStartInfo
            $si.FileName = Join-Path $PSHOME 'powershell.exe'
            $si.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
            $si.WorkingDirectory = $PSScriptRoot
            $si.UseShellExecute = $false
            $si.CreateNoWindow = $true
            $null = [System.Diagnostics.Process]::Start($si)
        } catch {
            Write-Host ('Could not open the window: ' + $_.Exception.Message)
            exit 4
        }
    }
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ------------------------------------------------------------------ constantes
$PASTA_SAVES  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'NFS Most Wanted'
# as copias de seguranca vao para uma pasta IRMA da de saves, nunca para dentro dela:
# o jogo trata cada subpasta de 'NFS Most Wanted' como perfil
$PASTA_COPIAS = $PASTA_SAVES + ' - backups'
$OFFSET_NOME  = 0x5A31   # onde o nome do jogador comeca
$CAMPO_NOME   = 35       # caracteres uteis antes do proximo registro
$INICIO_MD5   = 0x34     # o corpo somado no checksum comeca aqui
$TAM_MD5      = 16       # ...e o MD5 ocupa os 16 bytes finais
$MAGIA        = '20CM'

# -------------------------------------------------------------------- funcoes
function Get-NomeInterno([byte[]] $b) {
    $fim = $OFFSET_NOME
    while ($fim -lt $b.Length -and $b[$fim] -ne 0) { $fim++ }
    return [Text.Encoding]::ASCII.GetString($b, $OFFSET_NOME, $fim - $OFFSET_NOME)
}

function Get-Md5Calculado([byte[]] $b) {
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $corpo = New-Object byte[] ($b.Length - $INICIO_MD5 - $TAM_MD5)
        [Array]::Copy($b, $INICIO_MD5, $corpo, 0, $corpo.Length)
        return $md5.ComputeHash($corpo)
    } finally { $md5.Dispose() }
}

# alem do MD5, o cabecalho do save tem tres CRC32 (o conteiner da EA): [0x10] = CRC de 0x1C..0x23,
# [0x14] = CRC de 0x24 ate o fim (inclui o nome e o MD5), [0x18] = CRC de 0x00..0x17 (o proprio
# cabecalho). Polinomio 0x04C11DB7 sem refletir; os 4 primeiros bytes entram invertidos
$TABELA_CRC = New-Object 'uint32[]' 256
for ($i = 0; $i -lt 256; $i++) {
    $c = [long]$i -shl 24
    for ($k = 0; $k -lt 8; $k++) {
        if ($c -band 0x80000000L) { $c = (($c -shl 1) -bxor 0x04C11DB7L) -band 0xFFFFFFFFL } else { $c = ($c -shl 1) -band 0xFFFFFFFFL }
    }
    $TABELA_CRC[$i] = [uint32]$c
}

function Get-CrcEA([byte[]] $b, [int] $inicio, [int] $fim) {
    $c = ((([long]$b[$inicio] -shl 24) -bor ([long]$b[$inicio + 1] -shl 16) -bor ([long]$b[$inicio + 2] -shl 8) -bor $b[$inicio + 3]) -bxor 0xFFFFFFFFL)
    for ($i = $inicio + 4; $i -lt $fim; $i++) {
        $c = ((($c -shl 8) -band 0xFFFFFFFFL) -bor $b[$i]) -bxor $TABELA_CRC[$c -shr 24]
    }
    return [uint32]($c -bxor 0xFFFFFFFFL)
}

# nessa ordem: o CRC do cabecalho cobre os outros dois
function Set-CrcCabecalho([byte[]] $b) {
    [BitConverter]::GetBytes((Get-CrcEA $b 0x1C 0x24)).CopyTo($b, 0x10)
    [BitConverter]::GetBytes((Get-CrcEA $b 0x24 $b.Length)).CopyTo($b, 0x14)
    [BitConverter]::GetBytes((Get-CrcEA $b 0 0x18)).CopyTo($b, 0x18)
}

function Test-CrcCabecalho([byte[]] $b) {
    if ($b.Length -lt 0x28) { return $false }
    return ([BitConverter]::ToUInt32($b, 0x10) -eq (Get-CrcEA $b 0x1C 0x24)) -and
           ([BitConverter]::ToUInt32($b, 0x14) -eq (Get-CrcEA $b 0x24 $b.Length)) -and
           ([BitConverter]::ToUInt32($b, 0x18) -eq (Get-CrcEA $b 0 0x18))
}

function Test-Integro([byte[]] $b) {
    if ($b.Length -le ($INICIO_MD5 + $TAM_MD5)) { return $false }
    $calc = Get-Md5Calculado $b
    for ($i = 0; $i -lt $TAM_MD5; $i++) {
        if ($calc[$i] -ne $b[$b.Length - $TAM_MD5 + $i]) { return $false }
    }
    return $true
}

function Test-EhSave([byte[]] $b) {
    if ($b.Length -le ($OFFSET_NOME + $CAMPO_NOME)) { return $false }
    return ([Text.Encoding]::ASCII.GetString($b, 0, 4) -eq $MAGIA)
}

# o MD5 certo NAO prova que o nome esta em 0x5A31: outra versao do jogo pode usar o mesmo MD5 com
# outro layout. Antes de escrever, o campo tem de PARECER o campo do nome: o tamanho do cabecalho
# bate com o arquivo, 1 a 35 caracteres ASCII imprimiveis e so zeros ate o fim dos 36 bytes.
# Se nao parecer, escrever ali estragaria outro dado - e o MD5 novo esconderia o estrago
function Test-FormatoConhecido([byte[]] $b) {
    if ($b.Length -lt 16 -or [BitConverter]::ToUInt32($b, 4) -ne $b.Length) { return $false }
    $i = 0
    while ($i -le $CAMPO_NOME -and $b[$OFFSET_NOME + $i] -ge 32 -and $b[$OFFSET_NOME + $i] -le 126) { $i++ }
    if ($i -lt 1 -or $i -gt $CAMPO_NOME) { return $false }
    for (; $i -le $CAMPO_NOME; $i++) { if ($b[$OFFSET_NOME + $i] -ne 0) { return $false } }
    return $true
}

function Get-Perfis {
    $lista = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    # -LiteralPath em tudo: sem ele, '[BR]Nome' vira curinga e o perfil some
    if (-not (Test-Path -LiteralPath $PASTA_SAVES)) { return $lista }
    foreach ($dir in (Get-ChildItem -LiteralPath $PASTA_SAVES -Directory -EA SilentlyContinue | Sort-Object Name)) {
        $arq = Join-Path $dir.FullName $dir.Name
        if (-not (Test-Path -LiteralPath $arq)) {
            $lista.Add([pscustomobject]@{
                Pasta = $dir.Name; NomeInterno = '-'; Integro = 'sem arquivo'
                Modificado = ''; Quando = $null; Caminho = ''; Valido = $false })
            continue
        }
        # travado ou sem permissao: aparece na lista e diz por que, nao some calado
        try { $b = [IO.File]::ReadAllBytes($arq) } catch {
            Log ("'{0}': nao consegui ler o save - {1}" -f $dir.Name, $_.Exception.GetBaseException().Message)
            $lista.Add([pscustomobject]@{
                Pasta = $dir.Name; NomeInterno = '-'; Integro = 'ilegivel'
                Modificado = ''; Quando = $null; Caminho = $arq; Valido = $false })
            continue
        }
        if (-not (Test-EhSave $b)) {
            $lista.Add([pscustomobject]@{
                Pasta = $dir.Name; NomeInterno = '-'; Integro = 'nao e save'
                Modificado = ''; Quando = $null; Caminho = $arq; Valido = $false })
            continue
        }
        if (-not (Test-FormatoConhecido $b)) {
            $lista.Add([pscustomobject]@{
                Pasta = $dir.Name; NomeInterno = '?'; Integro = 'outro formato'
                Modificado = ''; Quando = $null; Caminho = $arq; Valido = $false })
            continue
        }
        $lista.Add([pscustomobject]@{
            Pasta       = $dir.Name
            NomeInterno = (Get-NomeInterno $b)
            Integro     = $(if (Test-Integro $b) { 'sim' } else { 'NAO' })
            Modificado  = (Get-Item -LiteralPath $arq).LastWriteTime.ToString('dd/MM/yyyy HH:mm')
            Quando      = (Get-Item -LiteralPath $arq).LastWriteTime   # a coluna ordena por aqui: texto dd/MM sai fora de ordem
            Caminho     = $arq
            Valido      = (Test-Integro $b)
        })
    }
    return $lista
}

# copia COMPLETA da pasta do perfil (tudo que tem dentro) para
# '<saves> - backups\<perfil>_<aaaa-mm-dd_hh-mm-ss>'. Nunca escreve por cima de copia antiga:
# no mesmo segundo ganha _2, _3... Confere cada arquivo lendo de volta do disco. Qualquer
# falha lanca erro, e quem chamou nao muda nada
function New-CopiaPerfil([string] $pastaPerfil) {
    $script:CopiaIncompleta = $null
    $base = Join-Path $PASTA_COPIAS ('{0}_{1}' -f (Split-Path $pastaPerfil -Leaf), (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    $destino = $base
    for ($n = 2; [IO.Directory]::Exists($destino) -or [IO.File]::Exists($destino); $n++) { $destino = '{0}_{1}' -f $base, $n }
    [void][IO.Directory]::CreateDirectory($destino)
    $script:CopiaIncompleta = $destino          # ate o fim conferir, ela nao serve
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        foreach ($d in [IO.Directory]::GetDirectories($pastaPerfil, '*', 'AllDirectories')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $destino $d.Substring($pastaPerfil.Length + 1)))
        }
        foreach ($f in [IO.Directory]::GetFiles($pastaPerfil, '*', 'AllDirectories')) {
            $alvo = Join-Path $destino $f.Substring($pastaPerfil.Length + 1)
            [IO.File]::Copy($f, $alvo, $false)      # $false: nunca por cima
            $orig = [BitConverter]::ToString($md5.ComputeHash([IO.File]::ReadAllBytes($f)))
            $novo = [BitConverter]::ToString($md5.ComputeHash([IO.File]::ReadAllBytes($alvo)))
            if ($orig -ne $novo) { throw ("a copia de '{0}' nao bateu com o original" -f $f) }
        }
    } finally { $md5.Dispose() }
    $script:CopiaIncompleta = $null
    return $destino
}

# ----------------------------------------------------------------------- janela
# ------------------------------------------------------------------ janela
$TEMA_ESTILOS = @'
    <!-- ===================================================== estilos
         Os mesmos nos tres projetos; as cores vem das chaves acima. -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource Superficie2}"/>
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Borda}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Fundo" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{DynamicResource CantoBotao}"/>
              <Border x:Name="Brilho" CornerRadius="{DynamicResource CantoBotao}" Background="Transparent"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Brilho" Property="Background" Value="{DynamicResource Realce}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Brilho" Property="Background" Value="{DynamicResource RealceForte}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Fundo" Property="BorderBrush" Value="{DynamicResource Destaque}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Fundo" Property="Background" Value="{DynamicResource Desligado}"/>
                <Setter TargetName="Fundo" Property="BorderBrush" Value="{DynamicResource Desligado}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextoApagado}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- o botao da acao principal: cheio, na cor de destaque -->
    <Style x:Key="Principal" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource Destaque}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Destaque}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextoNoDestaque}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextoSuave}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Caixa" Width="18" Height="18" CornerRadius="{DynamicResource CantoCaixa}" BorderThickness="1.5"
                      BorderBrush="{DynamicResource BordaForte}" Background="{DynamicResource Superficie2}" VerticalAlignment="Center">
                <Path x:Name="Marca" Data="M 3,8.2 L 6.4,11.6 L 12.8,4.6" Stroke="{DynamicResource TextoNoDestaque}" StrokeThickness="2.2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter x:Name="Rotulo" Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="Content" Value="{x:Null}">
                <Setter TargetName="Rotulo" Property="Margin" Value="0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Caixa" Property="BorderBrush" Value="{DynamicResource Destaque}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Caixa" Property="Background" Value="{DynamicResource Destaque}"/>
                <Setter TargetName="Caixa" Property="BorderBrush" Value="{DynamicResource Destaque}"/>
                <Setter TargetName="Marca" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource Superficie2}"/>
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Borda}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Texto}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Destaque}"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Moldura" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{DynamicResource CantoBotao}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" Focusable="False"
                            VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                            HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Moldura" Property="BorderBrush" Value="{DynamicResource Destaque}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- a grade: cartao sem linhas duras, cabecalho discreto, selecao suave -->
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="{DynamicResource Superficie}"/>
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowBackground" Value="{DynamicResource Superficie}"/>
      <Setter Property="AlternatingRowBackground" Value="{DynamicResource Superficie2}"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeight" Value="32"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{DynamicResource Superficie}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextoSuave}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Borda}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="10,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{DynamicResource Selecao}"/>
          <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- a caixinha dentro da grade: o mesmo desenho, centrada -->
    <Style x:Key="CaixaGrade" TargetType="CheckBox" BasedOn="{StaticResource {x:Type CheckBox}}">
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- barra de rolagem fina, sem setas: a do Windows e um trilho cinza-claro -->
    <ControlTemplate x:Key="PolegarRolagem" TargetType="Thumb">
      <Border x:Name="Polegar" Background="{DynamicResource BordaForte}" CornerRadius="4" Margin="2"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Polegar" Property="Background" Value="{DynamicResource TextoApagado}"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="11"/>
      <Setter Property="MinWidth" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
              <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
              <Track.Thumb><Thumb Template="{StaticResource PolegarRolagem}"/></Track.Thumb>
              <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="11"/>
          <Setter Property="MinHeight" Value="11"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="False" Focusable="False">
                  <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                  <Track.Thumb><Thumb Template="{StaticResource PolegarRolagem}"/></Track.Thumb>
                  <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- abas: arredondadas em cima, a escolhida se funde com o cartao -->
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="{DynamicResource Superficie}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TabPanel IsItemsHost="True" Margin="6,0,0,0"/>
              <Border Grid.Row="1" Background="{TemplateBinding Background}" CornerRadius="{DynamicResource CantoCartao}" Padding="{TemplateBinding Padding}">
                <ContentPresenter ContentSource="SelectedContent"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{DynamicResource TextoSuave}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Aba" Background="Transparent" CornerRadius="{DynamicResource CantoAba}" Padding="18,9" Margin="0,0,4,0">
              <ContentPresenter ContentSource="Header" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Aba" Property="Background" Value="{DynamicResource Superficie}"/>
                <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- bolinha (o mesmo desenho da caixa, redondo) -->
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="18" Height="18" VerticalAlignment="Center">
                <Ellipse x:Name="Anel" Stroke="{DynamicResource BordaForte}" StrokeThickness="1.5" Fill="{DynamicResource Superficie2}"/>
                <Ellipse x:Name="Miolo" Width="8" Height="8" Fill="{DynamicResource Destaque}" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Anel" Property="Stroke" Value="{DynamicResource Destaque}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Anel" Property="Stroke" Value="{DynamicResource Destaque}"/>
                <Setter TargetName="Miolo" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- opcao em forma de pilula (o tamanho, os cantos) -->
    <Style x:Key="Pilula" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="P" Background="{DynamicResource Superficie2}" BorderBrush="{DynamicResource Borda}" BorderThickness="1"
                    CornerRadius="{DynamicResource CantoBotao}" Padding="14,6">
              <ContentPresenter HorizontalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="P" Property="BorderBrush" Value="{DynamicResource Destaque}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="P" Property="Background" Value="{DynamicResource Destaque}"/>
                <Setter TargetName="P" Property="BorderBrush" Value="{DynamicResource Destaque}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextoNoDestaque}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- amostra de cor: bolinha cheia; a escolhida ganha um anel -->
    <Style x:Key="Amostra" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Width="34" Height="34" Background="Transparent">
              <Ellipse x:Name="Anel" Stroke="{DynamicResource Texto}" StrokeThickness="2" Visibility="Hidden"/>
              <Ellipse Margin="5" Fill="{TemplateBinding Background}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Anel" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Anel" Property="Opacity" Value="0.4"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Anel" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Anel" Property="Opacity" Value="1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- lista de escolha: caixa no tema e lista que abre num cartao -->
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Moldura" Background="{DynamicResource Superficie2}" BorderBrush="{DynamicResource Borda}"
                            BorderThickness="1" CornerRadius="{DynamicResource CantoBotao}">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" Data="M 0,0 L 4.5,4.5 L 9,0"
                            Stroke="{DynamicResource TextoSuave}" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Moldura" Property="BorderBrush" Value="{DynamicResource Destaque}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="12,0,32,0" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="{DynamicResource Superficie}" BorderBrush="{DynamicResource BordaForte}" BorderThickness="1"
                        CornerRadius="{DynamicResource CantoBotao}" Margin="0,4,0,0" Padding="4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                  <ScrollViewer MaxHeight="280"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <!-- desligada (ex.: o tema fixo no modo "Seguir o Windows") tem de parecer desligada -->
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Item" Background="Transparent" CornerRadius="6" Padding="10,6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Item" Property="Background" Value="{DynamicResource Selecao}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- cartao e titulo de secao -->
    <Style x:Key="Cartao" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Superficie}"/>
      <Setter Property="CornerRadius" Value="{DynamicResource CantoCartao}"/>
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Secao" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
'@

# ================================================================== aparencia
# O tema segue o Windows (claro ou escuro) e quem usa pode mudar tudo no botao
# "Aparência": tema, cor de destaque, tamanho, fonte e cantos. Muda na hora e
# fica salvo em aparencia.json, ao lado do programa.
#
# As cores nao estao escritas nos controles: cada um pede uma CHAVE ("Fundo",
# "Destaque"...) e Set-Aparencia troca o que cada chave vale. Por isso a janela
# muda de tema sem fechar.

# a ordem das cores em cada tema
$CHAVES_COR = 'Fundo', 'Superficie', 'Superficie2', 'Desligado', 'Borda', 'BordaForte', 'Selecao',
              'Texto', 'TextoSuave', 'TextoApagado', 'Titulo', 'Destaque', 'TextoNoDestaque',
              'Sucesso', 'Aviso', 'AvisoFundo', 'AvisoBorda', 'Erro', 'FundoRegistro', 'TextoRegistro',
              'Realce', 'RealceForte'

$TEMAS = [ordered]@{
    noite    = @{ Nome = 'Noite calma'; Escuro = $true
                  Cores = '#1E2030 #24273A #2B2F45 #262939 #363A4F #4A4F69 #363B55 #DCE1F5 #A5ADCB #6E738D #B7BDF8 #8BD5CA #1E2030 #A6DA95 #EED49F #33323B #675F57 #ED8796 #1A1C2A #B8C0E0 #12FFFFFF #24FFFFFF' }
    floresta = @{ Nome = 'Floresta à noite'; Escuro = $true
                  Cores = '#1B211E #222A25 #29322C #232A26 #34403A #4A5A51 #33413A #DCE8DF #A9BDB0 #6F8577 #A8D5B8 #8FCB9B #1B211E #A6DA95 #E9CF8F #2F2F28 #5E5A45 #E8939A #171C19 #B9CCBF #12FFFFFF #24FFFFFF' }
    porsol   = @{ Nome = 'Pôr do sol'; Escuro = $true
                  Cores = '#231E1F #2B2426 #332B2D #2A2325 #40363A #584A4E #44383C #F0E3E0 #C4B2AE #8A7974 #F5BDA6 #F2A38A #231E1F #B5D99C #F0D48A #3A3128 #6E5C45 #F08A8A #1E1A1B #DCCBC7 #12FFFFFF #24FFFFFF' }
    contraste = @{ Nome = 'Alto contraste'; Escuro = $true
                  Cores = '#000000 #0E0E0E #1A1A1A #141414 #5A5A5A #8A8A8A #23395B #FFFFFF #E6E6E6 #A0A0A0 #FFE066 #4FC3F7 #000000 #7CFC8A #FFE066 #1E1A00 #807000 #FF7A7A #050505 #F0F0F0 #26FFFFFF #44FFFFFF' }
    manha    = @{ Nome = 'Manhã serena'; Escuro = $false
                  Cores = '#F4F1EA #FFFFFF #F8F5EF #ECE8E0 #E3DCD0 #CBC2B3 #E3EFEA #3A3934 #6F6A60 #A69F93 #41708A #5E9C8A #FFFFFF #4C8A5A #8A6214 #FBF1DC #E9D3A4 #B4485A #FBF9F5 #57544C #0A000000 #16000000' }
    lavanda  = @{ Nome = 'Lavanda'; Escuro = $false
                  Cores = '#F3F1F8 #FFFFFF #F8F6FC #EAE7F1 #E0DCEB #C7C0D9 #ECE7F7 #37344A #6B6684 #A39EB8 #6A55A8 #8A72C9 #FFFFFF #4C8A5A #8A6214 #FBF1DC #E9D3A4 #B4485A #FBFAFE #4F4B63 #0A000000 #16000000' }
}

$DESTAQUES = [ordered]@{
    'Verde-água' = '#8BD5CA'; 'Azul' = '#8AADF4'; 'Lavanda' = '#B7BDF8'; 'Rosa' = '#F5BDE6'
    'Pêssego' = '#F5A97F'; 'Amarelo' = '#EED49F'; 'Verde' = '#A6DA95'; 'Coral' = '#ED8796'
}
# cantos: cartao, botao, caixinha
$CANTOS = [ordered]@{ redondos = @(16, 11, 7); suaves = @(12, 8, 5); retos = @(3, 3, 2) }
$ZOOMS  = @(0.9, 1.0, 1.15, 1.3)
$FONTES = @('Segoe UI', 'Segoe UI Variable Text', 'Bahnschrift', 'Calibri', 'Candara', 'Verdana', 'Georgia') |
          Where-Object { $f = $_; [Windows.Media.Fonts]::SystemFontFamilies | Where-Object { $_.Source -eq $f } }

$ARQ_APARENCIA = Join-Path $PSScriptRoot 'aparencia.json'

function New-AparenciaPadrao {
    [pscustomobject]@{ Modo = 'windows'; Tema = 'noite'; TemaEscuro = 'noite'; TemaClaro = 'manha'
                       Destaque = ''; Zoom = 1.0; Fonte = 'Segoe UI'; Cantos = 'suaves' }
}

# le aparencia.json item por item: valor estranho volta ao padrao
function Get-Aparencia {
    $a = New-AparenciaPadrao
    try { $j = [IO.File]::ReadAllText($ARQ_APARENCIA) | ConvertFrom-Json } catch { return $a }
    if ($j.Modo -in 'windows', 'fixo') { $a.Modo = $j.Modo }
    foreach ($k in 'Tema', 'TemaEscuro', 'TemaClaro') { if ($j.$k -and $TEMAS.Contains([string]$j.$k)) { $a.$k = [string]$j.$k } }
    if ([string]$j.Destaque -match '^#[0-9A-Fa-f]{6}$') { $a.Destaque = [string]$j.Destaque }
    if ($j.Zoom -as [double] -and $ZOOMS -contains [double]$j.Zoom) { $a.Zoom = [double]$j.Zoom }
    if ($FONTES -contains [string]$j.Fonte) { $a.Fonte = [string]$j.Fonte }
    if ($j.Cantos -and $CANTOS.Contains([string]$j.Cantos)) { $a.Cantos = [string]$j.Cantos }
    return $a
}

function Save-Aparencia($a) {
    try { [IO.File]::WriteAllText($ARQ_APARENCIA, ($a | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)); return $true }
    catch { return $false }        # pasta so de leitura: vale ate fechar, so nao fica salvo
}

# o Windows guarda "apps no modo claro" (1) ou escuro (0); sem a chave, e claro
function Test-WindowsEscuro {
    try {
        $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -ErrorAction Stop
        return ($v -eq 0)
    } catch { return $false }
}

function Get-TemaEfetivo($a) {
    if ($a.Modo -eq 'fixo') { return $a.Tema }
    if (Test-WindowsEscuro) { return $a.TemaEscuro } else { return $a.TemaClaro }
}

function New-Pincel([string] $hex) {
    $p = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
    $p.Freeze(); return $p
}

# contraste do WCAG 2 entre duas cores: de 1 a 21 (texto pede 4.5; borda e destaque, 3)
function Get-Luminancia([string] $hex) {
    $c = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    $l = foreach ($v in $c.R, $c.G, $c.B) { $v = $v / 255; if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow(($v + 0.055) / 1.055, 2.4) } }
    return 0.2126 * $l[0] + 0.7152 * $l[1] + 0.0722 * $l[2]
}
function Get-Contraste([string] $a, [string] $b) {
    $x = Get-Luminancia $a; $y = Get-Luminancia $b
    return ([Math]::Max($x, $y) + 0.05) / ([Math]::Min($x, $y) + 0.05)
}

# escurece a cor (o mesmo matiz) ate ter $minimo de contraste com o fundo
function Get-CorEscurecida([string] $hex, [string] $fundo, [double] $minimo) {
    $c = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    $r = $hex
    for ($k = 0.98; (Get-Contraste $r $fundo) -lt $minimo -and $k -gt 0; $k -= 0.02) {
        $r = '#{0:X2}{1:X2}{2:X2}' -f [int]($c.R * $k), [int]($c.G * $k), [int]($c.B * $k)
    }
    return $r
}

# texto escuro em cima de cor clara, branco em cima de cor escura: fica o que tiver mais
# contraste (WCAG). A conta por brilho errava nos verdes e cianos claros (#00FF00 dava branco)
function Test-CorClara([string] $hex) {
    return (Get-Contraste '#1B1B22' $hex) -gt (Get-Contraste '#FFFFFF' $hex)
}

# barra de titulo escura nos temas escuros (Windows 10 20H1+ e 11; antes disso, ignora)
if (-not ('BarraTitulo' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BarraTitulo {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int atributo, ref int valor, int tamanho);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    public static void IdApp(string id) { SetCurrentProcessExplicitAppUserModelID(id); }
    public static void Escura(IntPtr h, bool escura) {
        int v = escura ? 1 : 0;
        if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) DwmSetWindowAttribute(h, 19, ref v, 4);
    }
}
'@
}

# nome proprio na barra de tarefas: sem isto o Windows agrupa a janela com o PowerShell
# e mostra o icone dele, nao a logo
try { [BarraTitulo]::IdApp('OBebel.' + [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)) } catch { }

# o icone da janela e da barra de tarefas: a logo (o DrawingImage "Logo" da janela) em bitmap
function Set-IconeJanela([Windows.Window] $j) {
    $logo = $j.TryFindResource('Logo')
    if (-not $logo) { return }
    $v = New-Object Windows.Media.DrawingVisual
    $dc = $v.RenderOpen()
    $dc.DrawImage($logo, (New-Object Windows.Rect 0, 0, 64, 64))
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap 64, 64, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($v)
    $bmp.Freeze()
    $j.Icon = $bmp
}

$script:Aparencia = Get-Aparencia
$script:JanelasTema = New-Object System.Collections.ArrayList

# depois de crescer, a janela volta para dentro da area util (a tela sem a barra de tarefas).
# So mexe se o canto de cima estava nesta tela: noutro monitor, fica onde esta
function Set-DentroDaArea([Windows.Window] $j) {
    $area = [Windows.SystemParameters]::WorkArea
    if ([double]::IsNaN($j.Left) -or [double]::IsNaN($j.Top)) { return }
    if ($j.Left -lt $area.Left - 16 -or $j.Left -ge $area.Right -or $j.Top -lt $area.Top - 16 -or $j.Top -ge $area.Bottom) { return }
    $lg = $(if ($j.SizeToContent -ne 'Manual' -or [double]::IsNaN($j.Width)) { $j.ActualWidth } else { $j.Width })
    $at = $(if ($j.SizeToContent -ne 'Manual' -or [double]::IsNaN($j.Height)) { $j.ActualHeight } else { $j.Height })
    $j.Left = [Math]::Max($area.Left, [Math]::Min($j.Left, $area.Right - $lg))
    $j.Top  = [Math]::Max($area.Top, [Math]::Min($j.Top, $area.Bottom - $at))
}

# aplica a aparencia numa janela (a principal ou a da Aparência)
function Set-Aparencia([Windows.Window] $j) {
    $a = $script:Aparencia
    $t = $TEMAS[(Get-TemaEfetivo $a)]
    $cores = $t.Cores -split ' '
    for ($i = 0; $i -lt $CHAVES_COR.Count; $i++) { $j.Resources[$CHAVES_COR[$i]] = [Windows.Media.SolidColorBrush](New-Pincel $cores[$i]) }
    # o destaque: o escolhido ou o do tema. Nos temas claros ele escurece ate ter 3:1 com o Fundo:
    # a paleta e pastel (feita para fundo escuro) e sumia no claro
    $destaque = $(if ($a.Destaque) { $a.Destaque } else { $cores[[array]::IndexOf($CHAVES_COR, 'Destaque')] })
    if (-not $t.Escuro) { $destaque = Get-CorEscurecida $destaque $cores[0] 3 }
    $j.Resources['Destaque'] = [Windows.Media.SolidColorBrush](New-Pincel $destaque)
    if ($a.Destaque) {
        $j.Resources['TextoNoDestaque'] = [Windows.Media.SolidColorBrush](New-Pincel $(if (Test-CorClara $destaque) { '#1B1B22' } else { '#FFFFFF' }))
    }
    $c = $CANTOS[$a.Cantos]
    # o cast tira o embrulho do PowerShell (PSObject): sem ele o WPF recusa o valor
    $j.Resources['CantoCartao'] = [Windows.CornerRadius]::new($c[0])
    $j.Resources['CantoBotao']  = [Windows.CornerRadius]::new($c[1])
    $j.Resources['CantoCaixa']  = [Windows.CornerRadius]::new($c[2])
    $j.Resources['CantoAba']    = [Windows.CornerRadius]::new($c[0] - 2, $c[0] - 2, 0, 0)
    $j.FontFamily = New-Object Windows.Media.FontFamily $a.Fonte
    # tamanho: a janela inteira cresce junto (zoom), nao so a letra
    if ($j.Content -is [Windows.FrameworkElement]) {
        $j.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $a.Zoom, $a.Zoom
    }
    # o tamanho da janela so muda quando o ZOOM muda: trocar cor ou tema nao desfaz o que a pessoa
    # ajustou. Tag = tamanho a 100%, o zoom aplicado e o tamanho que ficou; se a pessoa mexeu no
    # tamanho depois disso, a conta parte do tamanho DELA
    if ($j.SizeToContent -eq 'Manual' -and -not [double]::IsNaN($j.Width)) {
        if (-not $j.Tag) { $j.Tag = @($j.Width, $j.Height, 0, 0, 0) }
        $g = $j.Tag
        if ($j.WindowState -eq 'Normal' -and $g[2] -ne $a.Zoom) {
            if ($g[2] -and ([Math]::Abs($j.Width - $g[3]) -gt 1 -or [Math]::Abs($j.Height - $g[4]) -gt 1)) {
                $g[0] = $j.Width / $g[2]; $g[1] = $j.Height / $g[2]
            }
            $area = [Windows.SystemParameters]::WorkArea
            $j.Width  = [Math]::Min($g[0] * $a.Zoom, $area.Width)
            $j.Height = [Math]::Min($g[1] * $a.Zoom, $area.Height)
            $g[2] = $a.Zoom; $g[3] = $j.Width; $g[4] = $j.Height
            Set-DentroDaArea $j      # maior, ela nao pode sair da tela
        }
    }
    try { [BarraTitulo]::Escura((New-Object Windows.Interop.WindowInteropHelper $j).EnsureHandle(), $t.Escuro) } catch { }
}

function Update-JanelasTema { foreach ($j in @($script:JanelasTema)) { Set-Aparencia $j } }

# a janela principal chama isto antes do ShowDialog
function Use-Aparencia([Windows.Window] $j) {
    [void]$script:JanelasTema.Add($j)
    Set-Aparencia $j
    # se a pessoa trocar o tema do Windows com o programa aberto, acompanha
    $script:EscuroAntes = Test-WindowsEscuro
    $script:VigiaTema = New-Object Windows.Threading.DispatcherTimer
    $script:VigiaTema.Interval = [TimeSpan]::FromSeconds(2)
    $script:VigiaTema.Add_Tick({
        if ($script:Aparencia.Modo -ne 'windows') { return }
        $e = Test-WindowsEscuro
        if ($e -ne $script:EscuroAntes) { $script:EscuroAntes = $e; Update-JanelasTema }
    })
    $script:VigiaTema.Start()
}

# ------------------------------------------------------------ a janela Aparência
$XAML_APARENCIA = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Aparência" SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource Fundo}"
        FontSize="13" TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
<!--TEMA-->
  </Window.Resources>
  <!-- a rolagem segura a janela dentro da tela (a altura maxima vem do codigo); os botoes
       ficam fora dela, sempre a vista -->
  <DockPanel>
    <DockPanel DockPanel.Dock="Bottom" Width="470" HorizontalAlignment="Left" Margin="24,4,24,20">
      <Button x:Name="BotaoPadrao" Content="Voltar ao padrão" DockPanel.Dock="Left"/>
      <Button x:Name="BotaoPronto" Content="Pronto" Style="{StaticResource Principal}" Width="120" HorizontalAlignment="Right"/>
    </DockPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto" Focusable="False">
      <StackPanel Margin="24,20,24,0" Width="470">
        <TextBlock Text="Aparência" FontSize="21" FontFamily="Segoe UI Semibold" Foreground="{DynamicResource Titulo}"/>
        <TextBlock Text="Tudo muda na hora, e fica guardado para a próxima vez." Foreground="{DynamicResource TextoSuave}" Margin="0,4,0,16"/>

        <Border Style="{StaticResource Cartao}">
          <StackPanel>
            <TextBlock Text="Tema" Style="{StaticResource Secao}"/>
            <RadioButton x:Name="ModoWindows" GroupName="modo" Content="Seguir o Windows (claro ou escuro)"/>
            <Grid Margin="26,10,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="no modo escuro" Foreground="{DynamicResource TextoSuave}" Margin="0,0,0,4"/>
                <ComboBox x:Name="TemaEscuro"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Text="no modo claro" Foreground="{DynamicResource TextoSuave}" Margin="0,0,0,4"/>
                <ComboBox x:Name="TemaClaro"/>
              </StackPanel>
            </Grid>
            <RadioButton x:Name="ModoFixo" GroupName="modo" Content="Sempre o mesmo tema" Margin="0,14,0,0"/>
            <ComboBox x:Name="TemaFixo" Margin="26,8,0,0" Width="210" HorizontalAlignment="Left"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Cartao}">
          <StackPanel>
            <TextBlock Text="Cor de destaque" Style="{StaticResource Secao}"/>
            <WrapPanel x:Name="Cores"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <TextBlock Text="ou um código" Foreground="{DynamicResource TextoSuave}" VerticalAlignment="Center"/>
              <TextBox x:Name="CorPropria" Width="110" Height="32" Margin="10,0,0,0" MaxLength="7"/>
              <TextBlock x:Name="CorAviso" Foreground="{DynamicResource TextoApagado}" VerticalAlignment="Center" Margin="10,0,0,0" Text="ex.: #8BD5CA"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Cartao}">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition/>
              <RowDefinition/>
              <RowDefinition/>
            </Grid.RowDefinitions>
            <TextBlock Text="Tamanho" Style="{StaticResource Secao}" Margin="0,6,18,0"/>
            <WrapPanel x:Name="Zooms" Grid.Column="1"/>
            <TextBlock Grid.Row="1" Text="Fonte" Style="{StaticResource Secao}" Margin="0,10,18,0"/>
            <ComboBox x:Name="Fonte" Grid.Row="1" Grid.Column="1" Width="210" HorizontalAlignment="Left" Margin="0,4,0,10"/>
            <TextBlock Grid.Row="2" Text="Cantos" Style="{StaticResource Secao}" Margin="0,6,18,0"/>
            <WrapPanel x:Name="Cantos" Grid.Row="2" Grid.Column="1"/>
          </Grid>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

function New-Opcao([string] $estilo, $conteudo, $valor, [string] $grupo) {
    $r = New-Object Windows.Controls.RadioButton
    $r.Style = $script:DlgAparencia.Resources[$estilo]
    $r.Content = $conteudo; $r.Tag = $valor; $r.GroupName = $grupo
    return $r
}

function Set-Lista([Windows.Controls.ComboBox] $c, [bool[]] $quais, [string] $atual) {
    $c.Items.Clear()
    foreach ($id in $TEMAS.Keys) {
        if ($quais -notcontains $TEMAS[$id].Escuro) { continue }
        $i = New-Object Windows.Controls.ComboBoxItem
        $i.Content = $TEMAS[$id].Nome; $i.Tag = $id
        [void]$c.Items.Add($i)
        if ($id -eq $atual) { $c.SelectedItem = $i }
    }
}

# tela -> $script:Aparencia, aplica em todas as janelas e grava
function Update-Aparencia {
    if ($script:DlgCarregando) { return }
    $d = $script:DlgAparencia
    $a = $script:Aparencia
    $a.Modo = $(if ($d.FindName('ModoFixo').IsChecked) { 'fixo' } else { 'windows' })
    foreach ($par in @(@('TemaEscuro', 'TemaEscuro'), @('TemaClaro', 'TemaClaro'), @('TemaFixo', 'Tema'))) {
        $sel = $d.FindName($par[0]).SelectedItem
        if ($sel) { $a.($par[1]) = $sel.Tag }
    }
    $d.FindName('TemaEscuro').IsEnabled = ($a.Modo -eq 'windows')
    $d.FindName('TemaClaro').IsEnabled = ($a.Modo -eq 'windows')
    $d.FindName('TemaFixo').IsEnabled = ($a.Modo -eq 'fixo')
    foreach ($r in $d.FindName('Zooms').Children) { if ($r.IsChecked) { $a.Zoom = [double]$r.Tag } }
    foreach ($r in $d.FindName('Cantos').Children) { if ($r.IsChecked) { $a.Cantos = [string]$r.Tag } }
    foreach ($r in $d.FindName('Cores').Children) { if ($r.IsChecked) { $a.Destaque = [string]$r.Tag } }
    if ($d.FindName('Fonte').SelectedItem) { $a.Fonte = [string]$d.FindName('Fonte').SelectedItem.Tag }
    Update-JanelasTema
    [void](Save-Aparencia $a)
}

# $script:Aparencia -> tela (ao abrir e no "Voltar ao padrão")
function Show-AparenciaNaTela {
    $script:DlgCarregando = $true
    try {
        $d = $script:DlgAparencia
        $a = $script:Aparencia
        $d.FindName('ModoWindows').IsChecked = ($a.Modo -eq 'windows')
        $d.FindName('ModoFixo').IsChecked = ($a.Modo -eq 'fixo')
        Set-Lista $d.FindName('TemaEscuro') @($true) $a.TemaEscuro
        Set-Lista $d.FindName('TemaClaro') @($false) $a.TemaClaro
        Set-Lista $d.FindName('TemaFixo') @($true, $false) $a.Tema
        foreach ($r in $d.FindName('Zooms').Children) { $r.IsChecked = ([double]$r.Tag -eq $a.Zoom) }
        foreach ($r in $d.FindName('Cantos').Children) { $r.IsChecked = ([string]$r.Tag -eq $a.Cantos) }
        foreach ($r in $d.FindName('Cores').Children) { $r.IsChecked = ([string]$r.Tag -eq $a.Destaque) }
        foreach ($i in $d.FindName('Fonte').Items) { if ($i.Tag -eq $a.Fonte) { $d.FindName('Fonte').SelectedItem = $i } }
        $d.FindName('CorPropria').Text = $(if ($a.Destaque -and -not ($DESTAQUES.Values -contains $a.Destaque)) { $a.Destaque } else { '' })
        $d.FindName('TemaEscuro').IsEnabled = ($a.Modo -eq 'windows')
        $d.FindName('TemaClaro').IsEnabled = ($a.Modo -eq 'windows')
        $d.FindName('TemaFixo').IsEnabled = ($a.Modo -eq 'fixo')
    } finally { $script:DlgCarregando = $false }
}

function New-JanelaAparencia([Windows.Window] $dono) {
    $d = [Windows.Markup.XamlReader]::Parse($XAML_APARENCIA.Replace('<!--TEMA-->', $TEMA_ESTILOS))
    $script:DlgAparencia = $d
    # nunca mais alta que a area util da tela: o resto rola (o ScrollViewer do XAML)
    $d.MaxHeight = [Windows.SystemParameters]::WorkArea.Height
    if ($dono -and $dono.IsVisible) { $d.Owner = $dono }
    if ($dono) { $d.Icon = $dono.Icon }
    $cores = $d.FindName('Cores')
    $tema = New-Opcao 'Pilula' 'do tema' '' 'cor'
    $tema.Margin = '0,2,10,8'
    [void]$cores.Children.Add($tema)
    foreach ($nome in $DESTAQUES.Keys) {
        $r = New-Opcao 'Amostra' $null $DESTAQUES[$nome] 'cor'
        $r.Background = [Windows.Media.SolidColorBrush](New-Pincel $DESTAQUES[$nome])
        $r.ToolTip = $nome
        [void]$cores.Children.Add($r)
    }
    foreach ($z in $ZOOMS) { [void]$d.FindName('Zooms').Children.Add((New-Opcao 'Pilula' ('{0}%' -f [int]($z * 100)) $z 'zoom')) }
    $nomesCanto = @{ redondos = 'Bem redondos'; suaves = 'Suaves'; retos = 'Retos' }
    foreach ($k in $CANTOS.Keys) { [void]$d.FindName('Cantos').Children.Add((New-Opcao 'Pilula' $nomesCanto[$k] $k 'canto')) }
    foreach ($f in $FONTES) {
        $i = New-Object Windows.Controls.ComboBoxItem
        $i.Content = $f; $i.Tag = $f; $i.FontFamily = New-Object Windows.Media.FontFamily $f
        [void]$d.FindName('Fonte').Items.Add($i)
    }
    Show-AparenciaNaTela

    foreach ($n in 'ModoWindows', 'ModoFixo') { $d.FindName($n).Add_Checked({ Update-Aparencia }) }
    foreach ($n in 'TemaEscuro', 'TemaClaro', 'TemaFixo', 'Fonte') { $d.FindName($n).Add_SelectionChanged({ Update-Aparencia }) }
    foreach ($n in 'Zooms', 'Cantos', 'Cores') { foreach ($r in $d.FindName($n).Children) { $r.Add_Checked({ Update-Aparencia }) } }
    $d.FindName('CorPropria').Add_TextChanged({
        $d = $script:DlgAparencia
        $txt = $d.FindName('CorPropria').Text.Trim()
        if ($txt -and $txt -notmatch '^#') { $txt = '#' + $txt }
        if ($txt -match '^#[0-9A-Fa-f]{6}$') {
            $script:Aparencia.Destaque = $txt.ToUpper()
            foreach ($r in $d.FindName('Cores').Children) { $r.IsChecked = $false }
            $d.FindName('CorAviso').Text = 'ok'
            Update-JanelasTema
            [void](Save-Aparencia $script:Aparencia)
        } elseif ($txt) { $d.FindName('CorAviso').Text = 'use #RRGGBB' } else { $d.FindName('CorAviso').Text = 'ex.: #8BD5CA' }
    })
    $d.FindName('BotaoPadrao').Add_Click({
        $script:Aparencia = New-AparenciaPadrao
        Show-AparenciaNaTela
        Update-JanelasTema
        [void](Save-Aparencia $script:Aparencia)
    })
    $d.FindName('BotaoPronto').Add_Click({ $script:DlgAparencia.Close() })
    $d.Add_Closed({ $script:JanelasTema.Remove($script:DlgAparencia) })
    # o tamanho muda o dialogo inteiro: se ele crescer para fora da tela, volta para dentro
    $d.Add_SizeChanged({ Set-DentroDaArea $args[0] })
    [void]$script:JanelasTema.Add($d)
    Set-Aparencia $d
    return $d
}

# o botao "Aparência" da janela principal
function Show-JanelaAparencia([Windows.Window] $dono) {
    $d = New-JanelaAparencia $dono
    [void]$d.ShowDialog()
}

# ------------------------------------------------- a pergunta antes da 1a mudanca
$XAML_PERGUNTA = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Antes de mudar o save" SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource Fundo}"
        FontSize="13" TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
<!--TEMA-->
  </Window.Resources>
  <!-- a rolagem segura a janela dentro da tela (a altura maxima vem do codigo); os botoes
       ficam fora dela, sempre a vista -->
  <DockPanel>
    <DockPanel DockPanel.Dock="Bottom" Width="520" HorizontalAlignment="Left" Margin="24,18,24,20">
      <Button x:Name="BotaoAbrirSaves" Content="Abrir a pasta de saves" DockPanel.Dock="Left"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BotaoCancelar" Content="Cancelar" Margin="0,0,10,0"/>
        <Button x:Name="BotaoContinuar" Content="Continuar" Style="{StaticResource Principal}" MinWidth="120"/>
      </StackPanel>
    </DockPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto" Focusable="False">
      <StackPanel Margin="24,20,24,0" Width="520">
        <TextBlock Text="Antes de mudar o save: copia de seguranca" FontSize="19" FontFamily="Segoe UI Semibold"
                   Foreground="{DynamicResource Titulo}" TextWrapping="Wrap"/>
        <TextBlock Foreground="{DynamicResource Texto}" TextWrapping="Wrap" Margin="0,12,0,6"
                   Text="Antes de CADA mudanca, este programa guarda sozinho uma copia completa da pasta do perfil, com data e hora no nome, em:"/>
        <TextBox x:Name="CaminhoCopias" IsReadOnly="True" TextWrapping="Wrap" Padding="8,6" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
        <Border Background="{DynamicResource AvisoFundo}" BorderBrush="{DynamicResource AvisoBorda}" BorderThickness="1"
                CornerRadius="{DynamicResource CantoBotao}" Padding="12,10" Margin="0,14,0,0">
          <StackPanel>
            <TextBlock Foreground="{DynamicResource Texto}" FontWeight="Bold" TextWrapping="Wrap"
                       Text="Recomendado: faca tambem a sua propria copia. Com o jogo fechado, copie a pasta de saves INTEIRA para outro lugar (um pendrive, a nuvem):"/>
            <TextBox x:Name="CaminhoSaves" IsReadOnly="True" TextWrapping="Wrap" Padding="8,6" Margin="0,8,0,0" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
            <TextBlock Foreground="{DynamicResource Texto}" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="Se algo der errado, e so colocar a pasta de volta com o jogo fechado."/>
          </StackPanel>
        </Border>
        <TextBlock Foreground="{DynamicResource TextoSuave}" TextWrapping="Wrap" Margin="0,12,0,0"
                   Text="Esta pergunta aparece uma vez cada vez que o programa e aberto. Cancelar nao muda nada."/>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

function New-JanelaPergunta([Windows.Window] $dono) {
    $d = [Windows.Markup.XamlReader]::Parse($XAML_PERGUNTA.Replace('<!--TEMA-->', $TEMA_ESTILOS))
    $script:DlgPergunta = $d
    # nunca mais alta que a area util da tela: o texto rola, os botoes ficam a vista
    $d.MaxHeight = [Windows.SystemParameters]::WorkArea.Height
    if ($dono -and $dono.IsVisible) { $d.Owner = $dono }
    if ($dono) { $d.Icon = $dono.Icon }
    $d.FindName('CaminhoCopias').Text = $PASTA_COPIAS
    $d.FindName('CaminhoSaves').Text = $PASTA_SAVES
    # abrir a pasta nao fecha a pergunta: a pessoa copia e depois escolhe
    $d.FindName('BotaoAbrirSaves').Add_Click({
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $PASTA_SAVES) -ErrorAction Stop }
        catch { Log ("Nao consegui abrir a pasta de saves: {0}" -f $_.Exception.Message) }
    })
    $d.FindName('BotaoContinuar').Add_Click({ $script:RespostaCopia = 'continuar'; $script:DlgPergunta.Close() })
    $d.FindName('BotaoCancelar').Add_Click({ $script:RespostaCopia = 'cancelar'; $script:DlgPergunta.Close() })
    $d.Add_PreviewKeyDown({ if ($args[1].Key -eq 'Escape') { $script:DlgPergunta.Close() } })
    $d.Add_Closed({ $script:JanelasTema.Remove($script:DlgPergunta) })
    # o tamanho (zoom) muda o dialogo inteiro: se ele crescer para fora da tela, volta para dentro
    $d.Add_SizeChanged({ Set-DentroDaArea $args[0] })
    [void]$script:JanelasTema.Add($d)
    Set-Aparencia $d
    return $d
}

# devolve 'continuar' ou 'cancelar'; fechar no X ou no Esc vale como cancelar
function Show-PerguntaCopia([Windows.Window] $dono) {
    $script:RespostaCopia = 'cancelar'
    $d = New-JanelaPergunta $dono
    [void]$d.ShowDialog()
    return $script:RespostaCopia
}

$XAML_JANELA = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NFSMW Save Tool" Height="600" Width="820"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Fundo}"
        FontFamily="Segoe UI" FontSize="13" TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <DrawingImage x:Key="Logo">
      <DrawingImage.Drawing>
        <DrawingGroup>
        <GeometryDrawing Brush="Transparent" Geometry="M0,0 H64 V64 H0 Z"/>
        <GeometryDrawing>
          <GeometryDrawing.Brush>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#FBBF24" Offset="0"/>
              <GradientStop Color="#E0452A" Offset="1"/>
            </LinearGradientBrush>
          </GeometryDrawing.Brush>
          <GeometryDrawing.Geometry><RectangleGeometry Rect="2,2,60,60" RadiusX="15" RadiusY="15"/></GeometryDrawing.Geometry>
        </GeometryDrawing>
        <GeometryDrawing>
          <GeometryDrawing.Brush>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#30FFFFFF" Offset="0"/>
              <GradientStop Color="#00FFFFFF" Offset="0.55"/>
            </LinearGradientBrush>
          </GeometryDrawing.Brush>
          <GeometryDrawing.Geometry><RectangleGeometry Rect="2,2,60,60" RadiusX="15" RadiusY="15"/></GeometryDrawing.Geometry>
        </GeometryDrawing>
        <!-- sombra + corpo do disquete (canto chanfrado em cima a direita) -->
        <GeometryDrawing Brush="#33401004" Geometry="M15.5,16 H40 L47.5,23.5 V46 A3,3 0 0 1 44.5,49 H18.5 A3,3 0 0 1 15.5,46 Z"/>
        <GeometryDrawing Brush="#FFFFFF" Geometry="M14,14.5 H38.5 L46,22 V44.5 A3,3 0 0 1 43,47.5 H17 A3,3 0 0 1 14,44.5 Z"/>
        <!-- a portinha de metal -->
        <GeometryDrawing Brush="#7A2E1A" Geometry="M20,14.5 H36 V24 A1.5,1.5 0 0 1 34.5,25.5 H21.5 A1.5,1.5 0 0 1 20,24 Z"/>
        <GeometryDrawing Brush="#FFFFFF" Geometry="M30,16.5 H33.5 V23.5 H30 Z"/>
        <!-- etiqueta quadriculada (bandeira de corrida) -->
        <GeometryDrawing Brush="#3A1A10" Geometry="M18.5,30.5 H41.5 V44 H18.5 Z"/>
        <GeometryDrawing Brush="#FFFFFF" Geometry="M18.5,30.5 H22.33 V34 H18.5 Z M26.17,30.5 H30 V34 H26.17 Z M33.83,30.5 H37.67 V34 H33.83 Z
                                                  M22.33,34 H26.17 V37.5 H22.33 Z M30,34 H33.83 V37.5 H30 Z M37.67,34 H41.5 V37.5 H37.67 Z
                                                  M18.5,37.5 H22.33 V41 H18.5 Z M26.17,37.5 H30 V41 H26.17 Z M33.83,37.5 H37.67 V41 H33.83 Z
                                                  M22.33,41 H26.17 V44 H22.33 Z M30,41 H33.83 V44 H30 Z M37.67,41 H41.5 V44 H37.67 Z"/>
        <!-- selo: renomear (lapis) -->
        <GeometryDrawing Brush="#FACC15">
          <GeometryDrawing.Pen><Pen Brush="#FFFFFF" Thickness="2.5"/></GeometryDrawing.Pen>
          <GeometryDrawing.Geometry><EllipseGeometry Center="47,47" RadiusX="10.5" RadiusY="10.5"/></GeometryDrawing.Geometry>
        </GeometryDrawing>
        <GeometryDrawing Brush="#3A1A10" Geometry="M 42.4,49.8 L 49.6,42.6 L 52.4,45.4 L 45.2,52.6 Z M 42.4,49.8 L 45.2,52.6 L 41.2,53.8 Z"/>
        <GeometryDrawing Brush="#E0452A" Geometry="M 49.6,42.6 L 50.8,41.4 A 1.4,1.4 0 0 1 52.8,41.4 L 53.6,42.2 A 1.4,1.4 0 0 1 53.6,44.2 L 52.4,45.4 Z"/>
        </DrawingGroup>
      </DrawingImage.Drawing>
    </DrawingImage>
<!--TEMA-->
  </Window.Resources>
  <Grid Margin="22,18,22,20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <!-- a lista de perfis nunca some (tela pequena + Tamanho grande): o registro embaixo cede antes -->
      <RowDefinition Height="*" MinHeight="120"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="130"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Image Source="{StaticResource Logo}" Width="50" Height="50" Margin="0,0,14,0" VerticalAlignment="Center"/>
      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <TextBlock Text="NFSMW Save Tool" Foreground="{DynamicResource Titulo}" FontSize="22" FontFamily="Segoe UI Semibold"/>
        <TextBlock Foreground="{DynamicResource TextoSuave}" TextWrapping="Wrap" Margin="0,5,0,0"
                   Text="Renomeia o perfil do Need for Speed: Most Wanted (2005) por dentro do save, recalculando o checksum. Sem isso o jogo recusa o arquivo."/>
      </StackPanel>
      <Button x:Name="BotaoAparencia" Grid.Column="2" VerticalAlignment="Top" Margin="16,2,0,0" Padding="14,0"
              ToolTip="Tema, cor de destaque, tamanho, fonte e cantos">
        <StackPanel Orientation="Horizontal">
          <Ellipse Width="11" Height="11" Fill="{DynamicResource Destaque}" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock Text="Aparência" VerticalAlignment="Center"/>
        </StackPanel>
      </Button>
    </Grid>

    <Border Grid.Row="1" Background="{DynamicResource Superficie}" CornerRadius="{DynamicResource CantoCartao}" Padding="6">
      <DataGrid x:Name="Grade" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single">
        <!-- save quebrado ou ignorado pelo jogo fica marcado, nao passa batido -->
        <DataGrid.RowStyle>
          <Style TargetType="DataGridRow">
            <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
            <Style.Triggers>
              <DataTrigger Binding="{Binding Valido}" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource TextoApagado}"/>
              </DataTrigger>
              <DataTrigger Binding="{Binding Integro}" Value="NAO">
                <Setter Property="Foreground" Value="{DynamicResource Erro}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </DataTrigger>
            </Style.Triggers>
          </Style>
        </DataGrid.RowStyle>
        <DataGrid.Columns>
          <DataGridTextColumn Header="Pasta"       Binding="{Binding Pasta}"       Width="210"/>
          <DataGridTextColumn Header="Nome dentro" Binding="{Binding NomeInterno}" Width="180"/>
          <DataGridTextColumn Header="Integro"     Binding="{Binding Integro}"     Width="100"/>
          <DataGridTextColumn Header="Modificado"  Binding="{Binding Modificado}"  Width="*" MinWidth="140" SortMemberPath="Quando"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>

    <Grid Grid.Row="2" Margin="0,14,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Novo nome:" Foreground="{DynamicResource Texto}" VerticalAlignment="Top" Margin="0,8,10,0"/>
      <StackPanel Grid.Column="1">
        <TextBox x:Name="CaixaNome" Height="34" MaxLength="35"/>
        <TextBlock x:Name="Contador" Foreground="{DynamicResource TextoApagado}" FontSize="11.5" Margin="4,4,0,0"
                   Text="ate 35 caracteres, somente ASCII"/>
      </StackPanel>
      <CheckBox Grid.Column="2" x:Name="MarcaPasta" Content="renomear a pasta tambem" VerticalAlignment="Top" Margin="16,8,16,0"/>
      <Button   Grid.Column="3" x:Name="BotaoAtualizar" Content="Atualizar" VerticalAlignment="Top" Margin="0,0,10,0"/>
      <Button   Grid.Column="4" x:Name="BotaoRenomear" Content="Renomear" Style="{StaticResource Principal}"
                VerticalAlignment="Top" MinWidth="120" IsEnabled="False"/>
    </Grid>

    <Border Grid.Row="3" Margin="0" Background="{DynamicResource FundoRegistro}" BorderBrush="{DynamicResource Borda}"
            BorderThickness="1" CornerRadius="{DynamicResource CantoCartao}">
      <ScrollViewer x:Name="Rolagem" VerticalScrollBarVisibility="Auto" Margin="2">
        <TextBox x:Name="Registro" Background="Transparent" Foreground="{DynamicResource TextoRegistro}" BorderThickness="0"
                 FontFamily="Cascadia Mono, Consolas" FontSize="12" IsReadOnly="True" TextWrapping="Wrap"
                 Padding="10,8" AcceptsReturn="True" VerticalContentAlignment="Top"/>
      </ScrollViewer>
    </Border>
  </Grid>
</Window>
'@
$janela = [Windows.Markup.XamlReader]::Parse($XAML_JANELA.Replace('<!--TEMA-->', $TEMA_ESTILOS))
Set-IconeJanela $janela

$Grade          = $janela.FindName('Grade')
$CaixaNome      = $janela.FindName('CaixaNome')
$MarcaPasta     = $janela.FindName('MarcaPasta')
$BotaoAtualizar = $janela.FindName('BotaoAtualizar')
$BotaoRenomear  = $janela.FindName('BotaoRenomear')
$Registro       = $janela.FindName('Registro')
$Rolagem        = $janela.FindName('Rolagem')
$Contador       = $janela.FindName('Contador')

function Log($texto) {
    $Registro.AppendText(("{0}  {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $texto))
    $Rolagem.ScrollToEnd()
}

function Atualizar {
    # @(): com 1 perfil so, o PowerShell devolveria um objeto solto (nao lista)
    # e a grade ficaria vazia
    $Grade.ItemsSource = @(Get-Perfis)
    $n = $Grade.Items.Count
    Log ("{0} perfil(is) em {1}" -f $n, $PASTA_SAVES)
    if ($n -eq 0) { Log 'Nenhum perfil encontrado. O jogo ja foi aberto ao menos uma vez?' }
}

# ------------------------------------------------------------------- renomear
$script:JaPerguntou = $false     # a pergunta da copia: uma vez cada vez que o programa abre
$BotaoRenomear.Add_Click({
    $sel = $Grade.SelectedItem
    if (-not $sel)          { Log 'Escolha um perfil na lista primeiro.'; return }
    if (-not $sel.Valido)   { Log ("'{0}' nao pode ser editado ({1})." -f $sel.Pasta, $sel.Integro); return }

    $novo = $CaixaNome.Text.Trim()
    if ($novo.Length -eq 0)          { Log 'Escreva o novo nome.'; return }
    if ($novo.Length -gt $CAMPO_NOME){ Log ("Nome longo demais: {0} de {1} caracteres." -f $novo.Length, $CAMPO_NOME); return }
    foreach ($c in $novo.ToCharArray()) {
        if ([int]$c -gt 126 -or [int]$c -lt 32) { Log 'Somente caracteres ASCII - o campo nao guarda acento.'; return }
    }
    # com 'renomear a pasta' o nome vira nome de pasta: simbolo de caminho, '..', CON ou ponto
    # no fim tiravam o save da pasta ou davam erro depois de ja ter gravado
    if ($MarcaPasta.IsChecked -and ($novo.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $novo.EndsWith('.') -or $novo -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?$')) {
        Log ("'{0}' nao serve como nome de pasta (sem \ / : * ? < > |, sem ponto no fim, sem CON/NUL). Troque o nome ou desmarque 'renomear a pasta tambem'." -f $novo); return
    }
    # nome de OUTRO perfil (pasta ou nome de dentro; -eq nao diferencia maiuscula): o jogo
    # mostraria dois perfis iguais, e a pasta de mesmo nome nao tem copia nenhuma
    $outro = @($Grade.Items | Where-Object { -not [object]::ReferenceEquals($_, $sel) -and ($_.Pasta -eq $novo -or ($_.Quando -and $_.NomeInterno -eq $novo)) })
    if ($outro.Count -gt 0 -or ($sel.Pasta -ne $novo -and [IO.Directory]::Exists($PASTA_SAVES + '\' + $novo))) {
        Log ("Ja existe um perfil chamado '{0}'. Escolha outro nome." -f $novo); return
    }
    # com 'renomear a pasta' o arquivo troca de nome DENTRO da pasta: um arquivo com o nome novo
    # (o .bak, por exemplo) seria apagado por cima
    if ($MarcaPasta.IsChecked -and $novo -ne $sel.Pasta) {
        $dentro = (Split-Path $sel.Caminho -Parent) + '\' + $novo
        if ([IO.File]::Exists($dentro) -or [IO.Directory]::Exists($dentro)) {
            Log ("A pasta do perfil ja tem um arquivo chamado '{0}', e com 'renomear a pasta' ele seria apagado. Escolha outro nome." -f $novo); return
        }
    }
    # com o jogo aberto, ele grava por cima o perfil que tem na memoria
    if ([Diagnostics.Process]::GetProcessesByName('speed').Length -gt 0) {
        Log 'O jogo esta aberto (speed.exe). Feche o jogo e clique em Renomear de novo. Nada foi mudado.'; return
    }

    # antes da PRIMEIRA mudanca desde que o programa abriu: diz onde vai a copia e recomenda
    # a copia propria. Cancelar, fechar ou erro ao mostrar = nada muda
    if (-not $script:JaPerguntou) {
        $resposta = 'cancelar'
        try { $resposta = Show-PerguntaCopia $janela } catch { Log ("ERRO ao mostrar a pergunta: {0}" -f $_.Exception.Message) }
        if ($resposta -ne 'continuar') { Log 'Cancelado. Nada foi mudado.'; return }
        $script:JaPerguntou = $true
    }

    # sem try, erro de disco so parava a linha: o resto seguia com dado velho e a
    # mensagem de verdade ia pro console escondido
    $gravando = $false
    $concluiu = $false
    try {
        $arq = $sel.Caminho
        $b = [IO.File]::ReadAllBytes($arq)

        if (-not (Test-Integro $b)) { Log 'Este save JA esta corrompido. Nao vou tocar nele.'; return }
        if (-not ((Test-EhSave $b) -and (Test-FormatoConhecido $b))) { Log 'Este save nao tem o formato conhecido (o nome nao esta onde deveria). Nao vou tocar nele.'; return }

        $antigo = Get-NomeInterno $b
        Log ("save : {0}" -f $arq)
        Log ("nome : '{0}' -> '{1}'" -f $antigo, $novo)

        # copia COMPLETA da pasta do perfil antes de CADA mudanca (o .bak abaixo so nasce na
        # primeira). Sem copia, sem mudanca
        try { $copia = New-CopiaPerfil (Split-Path $arq -Parent) }
        catch {
            $motivo = $_.Exception.GetBaseException().Message
            Log ("ERRO: a copia de seguranca falhou - {0}" -f $motivo)
            if ($script:CopiaIncompleta) { Log ("A copia incompleta em {0} nao serve; pode apagar." -f $script:CopiaIncompleta) }
            Log 'Por isso NADA foi mudado: o save continua como estava.'
            [System.Windows.MessageBox]::Show("A copia de seguranca do perfil falhou, entao NADA foi mudado.`n`n$motivo", 'NFSMW Save Tool') | Out-Null
            return
        }
        Log ("copia completa: {0}" -f $copia)

        $backup = $arq + '.bak'
        $bakVelho = Test-Path -LiteralPath $backup
        if (-not $bakVelho) {
            Copy-Item -LiteralPath $arq -Destination $backup -Force -ErrorAction Stop
            Log ("backup: {0}" -f $backup)
        } else {
            Log 'backup ja existia, mantido'
        }

        # campo de largura fixa: escreve o nome e zera o resto. Nada depois desloca.
        $bytesNome = [Text.Encoding]::ASCII.GetBytes($novo)
        for ($i = 0; $i -le $CAMPO_NOME; $i++) {
            $b[$OFFSET_NOME + $i] = $(if ($i -lt $bytesNome.Length) { $bytesNome[$i] } else { 0 })
        }

        # o passo que todo mundo esquece
        $novoMd5 = Get-Md5Calculado $b
        for ($i = 0; $i -lt $TAM_MD5; $i++) { $b[$b.Length - $TAM_MD5 + $i] = $novoMd5[$i] }
        # e depois do MD5 (o CRC de 0x14 cobre o MD5), os CRC32 do cabecalho
        Set-CrcCabecalho $b

        $gravando = $true
        [IO.File]::WriteAllBytes($arq, $b)

        # conferir lendo DE VOLTA do disco, nunca da memoria
        $conf = [IO.File]::ReadAllBytes($arq)
        $nomeOk = ((Get-NomeInterno $conf) -eq $novo)
        $somaOk = (Test-Integro $conf)
        $crcOk  = (Test-CrcCabecalho $conf)
        $tamOk  = ($conf.Length -eq $b.Length)
        Log ("nome dentro : '{0}'  {1}" -f (Get-NomeInterno $conf), $(if ($nomeOk) { 'OK' } else { 'FALHOU' }))
        Log ("checksum    : {0}" -f $(if ($somaOk) { 'OK' } else { 'FALHOU' }))
        Log ("crc32       : {0}" -f $(if ($crcOk) { 'OK' } else { 'FALHOU' }))
        Log ("tamanho     : {0} bytes {1}" -f $conf.Length, $(if ($tamOk) { 'OK' } else { 'MUDOU!' }))

        # o catch olha o disco e diz se precisa restaurar
        if (-not ($nomeOk -and $somaOk -and $crcOk -and $tamOk)) { throw 'a conferencia lendo do disco nao bateu' }

        $pastaOk = $true
        if ($MarcaPasta.IsChecked) {
            $pastaAtual = Split-Path $arq -Parent
            $alvo = Join-Path $PASTA_SAVES $novo
            $nomePasta = Split-Path $pastaAtual -Leaf
            if ($nomePasta -eq $novo) {
                # a propria pasta: so muda maiuscula/minuscula (ou nada), e para o Windows e o mesmo nome
                Log ("A pasta ja se chama '{0}'{1} - deixei pasta e arquivo como estavam." -f $nomePasta, $(if ($nomePasta -cne $novo) { ' (para o Windows, maiuscula e minuscula sao o mesmo nome)' } else { '' }))
                Log 'O nome dentro do jogo ja esta correto.'
            } elseif (Test-Path -LiteralPath $alvo) {
                Log ("A pasta '{0}' ja existe - deixei pasta e arquivo como estavam." -f $novo)
                Log 'O nome dentro do jogo ja esta correto.'
            } else {
                # a pasta vai primeiro: se ela estiver em uso, nada muda. Se o arquivo
                # falhar depois, a pasta volta - pasta e arquivo com nomes diferentes
                # o jogo ignora
                $movida = $false
                try {
                    Move-Item -LiteralPath $pastaAtual -Destination $alvo -Force -ErrorAction Stop
                    $movida = $true
                    Move-Item -LiteralPath (Join-Path $alvo (Split-Path $arq -Leaf)) -Destination (Join-Path $alvo $novo) -Force -ErrorAction Stop
                    $pastaOk = Test-Path -LiteralPath (Join-Path $alvo $novo)
                    Log ("pasta e arquivo renomeados para '{0}'  {1}" -f $novo, $(if ($pastaOk) { 'OK' } else { 'FALHOU' }))
                } catch {
                    $pastaOk = $false
                    Log ("pasta e arquivo NAO renomeados: {0}" -f $_.Exception.Message)
                    if ($movida) {
                        try   { Move-Item -LiteralPath $alvo -Destination $pastaAtual -Force -ErrorAction Stop }
                        catch { Log ("E a pasta nao voltou: renomeie '{0}' para '{1}' a mao." -f $alvo, (Split-Path $pastaAtual -Leaf)) }
                    }
                }
            }
        }

        if ($pastaOk) { Log 'Pronto. Abra o jogo e confira o nome do perfil.' }
        else          { Log 'Nome dentro do save trocado, mas a pasta deu erro (veja acima).' }
        Log ("A copia de antes desta mudanca ficou em: {0}" -f $copia)
        $concluiu = $true
    } catch {
        Log ("ERRO: {0}" -f $_.Exception.Message)
        if (-not $gravando) { Log 'O save nao foi alterado. Clique em Atualizar e tente de novo.'; return }
        # a gravacao chegou a comecar: so o disco diz se o save ficou inteiro
        $disco = $null
        try { $disco = [IO.File]::ReadAllBytes($arq) } catch { }
        if ($disco -and (Test-Integro $disco)) {
            Log ("O save no disco esta integro, com o nome '{0}' dentro. Nao precisa restaurar." -f (Get-NomeInterno $disco))
        } else {
            # a copia completa e de logo antes desta mudanca; o .bak pode ser bem mais velho
            Log ("ALGO DEU ERRADO. Com o jogo fechado, copie o que tem dentro de {0} de volta para {1}" -f $copia, (Split-Path $arq -Parent))
            Log ("(o .bak tambem existe: {0})" -f $backup)
            if ($bakVelho) { Log 'Atencao: esse .bak e de antes da PRIMEIRA alteracao - o que mudou depois dela se perde.' }
            [System.Windows.MessageBox]::Show("Algo deu errado. Com o jogo fechado, copie o que tem dentro de:`n$copia`n`nde volta para:`n$(Split-Path $arq -Parent)", 'NFSMW Save Tool') | Out-Null
        }
    }
    # fora do try: um erro ao reler a lista nao e erro do rename (e o catch acima
    # daria o alarme falso de "restaure do .bak")
    if ($concluiu) { Atualizar }
})

$BotaoAtualizar.Add_Click({ Atualizar })

# o botao so acende quando renomear faz sentido - erro que nao acontece
# e melhor que erro bem explicado
function AtualizarBotao {
    $sel  = $Grade.SelectedItem
    $novo = $CaixaNome.Text.Trim()
    $podeNome = $novo.Length -gt 0 -and $novo.Length -le $CAMPO_NOME
    if ($podeNome) {
        foreach ($c in $novo.ToCharArray()) {
            if ([int]$c -gt 126 -or [int]$c -lt 32) { $podeNome = $false; break }
        }
    }
    $BotaoRenomear.IsEnabled = ($sel -ne $null -and $sel.Valido -and $podeNome)

    if ($novo.Length -eq 0) {
        $Contador.Text = 'ate 35 caracteres, somente ASCII'
        $Contador.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextoApagado')
    } elseif (-not $podeNome) {
        $Contador.Text = 'esse nome nao serve: use somente letras e numeros sem acento'
        $Contador.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Erro')
    } else {
        $Contador.Text = ("{0} de {1} caracteres" -f $novo.Length, $CAMPO_NOME)
        # TextoSuave, nao Destaque: o destaque pode ser um pastel claro e o contador sumia no tema claro
        $Contador.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextoSuave')
    }
}

$Grade.Add_SelectionChanged({
    $sel = $Grade.SelectedItem
    if ($sel -and $sel.Valido) {
        $CaixaNome.Text = $sel.NomeInterno
    } elseif ($sel) {
        Log ("'{0}': {1} - nao da pra editar" -f $sel.Pasta, $sel.Integro)
    }
    AtualizarBotao
})

$CaixaNome.Add_TextChanged({ AtualizarBotao })

Log 'NFSMW Save Tool'
Log 'Escolha um perfil, escreva o novo nome e clique em Renomear.'
Log 'Feche o jogo antes de renomear.'
Log 'Antes de cada mudanca, uma copia completa do perfil vai para:'
Log ("   {0}" -f $PASTA_COPIAS)
Atualizar

# o botao Aparencia e o tema (segue o Windows; ver o bloco "aparencia" acima)
$janela.FindName('BotaoAparencia').Add_Click({ Show-JanelaAparencia $janela })
Use-Aparencia $janela
$janela.ShowDialog() | Out-Null
