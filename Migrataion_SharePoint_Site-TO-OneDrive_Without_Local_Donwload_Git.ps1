<# Script para permitir a migração de SharePoint Site para Onedrive de usuário - By Anderson Cardoso - 09/2024

####Pontos de atenção####
Testado em powershell 7.4, não roda em Powershell 5.X
É necessário registrar um APP no Portal Azure conforme documentação Readme.pdf
Um log de execução é gerado em c:\temp para verificar todo o processo.

###Recursos####
Autenticação baseada em Token, usa Client ID, Client Secret, e Tenant ID para autenticar em ambos SharePoint
Migra Pastas recursivamente do Sharepoint para Onedrive nuvem;

####Funcionamento####
Valida credenciais de acesso ao Site Sharepoint utilizando API do Microsoft Graph;
Conecta no Sharepoint e obtém a estrutura de arquivos e pastas;
Manipula arquivos em memória, verifica cada arquivo checando sua existência destino Onedrive;
Se não existe ele faz upload para o Servidor Onedrive nuvem; se o arquivo existe e sofreu modificação ele copia o arquivo modificado;

####Limitações####
Caso tenha problema ao obter token de acesso, recomendo que autentique com o usuário no Sharepoint via Broswer.
Na raiz do site Sharepoint, ele não migra os arquivos, precisam esta dentro de pastas.

#>

# Variáveis de autenticação
$tenantId = "Seu Tenant ID"    # Seu Tenant ID
$clientId = "Seu Client ID"      # Seu Client ID
$clientSecret = "Seu Client Secret" # Seu Client Secret
$oneDriveUser = "Usuário OneDrive@dominio.com.br"  # Usuário OneDrive

$domain = "empresa.sharepoint.com"  # Substitua pelo seu domínio do SharePoint
$siteName = "SeusiteSharepoint"      # Substitua pelo nome do seu site no SharePoint

# Caminho da pasta de origem no SharePoint e destino no OneDrive
$sourceFolderPath = "/Homologa"  # Substitua por sua pasta de origem no SharePoint, para migrar a raiz inteira use ""
$oneDriveBaseDestination = "/Homologa"  # Substitua pelo caminho desejado no OneDrive

# Caminho do arquivo de log
$logPath = "C:\temp\MigrationSharePoint-To-OneDrive.log"

# Função para escrever no log
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    
    # Verifica se o arquivo existe; se não, cria com a codificação UTF-8
    if (-not (Test-Path $logPath)) {
        Set-Content -Path $logPath -Value "" -Encoding UTF8
    }
    
    # Usa Add-Content para adicionar a nova mensagem ao log
    Add-Content -Path $logPath -Value $logMessage -Encoding UTF8
    Write-Host $logMessage 
}


# Função para obter o token de acesso
function Get-AccessToken {
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = $clientSecret
        resource      = "https://graph.microsoft.com/"
    }
    
    $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -Body $body
    return $response.access_token
}

# Função para obter o siteId do SharePoint
function Get-SiteId {
    param (
        [string]$accessToken,
        [string]$domain,
        [string]$siteName
    )
    $requestUrl = "https://graph.microsoft.com/v1.0/sites/${domain}:/sites/${siteName}"

    try {
        $response = Invoke-RestMethod -Method Get -Uri $requestUrl -Headers @{ Authorization = "Bearer $accessToken" }
        return $response.id
    } catch {
        Write-Log "Erro ao obter o siteId: $_"
        return $null
    }
}

# Função para obter itens do SharePoint (pastas e arquivos)
function Get-SharePointItems {
    param (
        [string]$folderPath = ""
    )

    # Formatar a URL corretamente
    $requestUrl = if ($folderPath -eq "") {
        "https://graph.microsoft.com/v1.0/sites/$siteId/drive/root/children"
    } else {
        "https://graph.microsoft.com/v1.0/sites/$siteId/drive/root:/$($folderPath):/children"
    }

    Write-Log "Solicitando itens de: $requestUrl"
    $accessToken = Get-AccessToken

    if (-not $accessToken) {
        Write-Log "Token de acesso não obtido. Abortando."
        return $null
    }

    try {
        $headers = @{ "Authorization" = "Bearer $accessToken" }
        $items = Invoke-RestMethod -Method Get -Uri $requestUrl -Headers $headers
        return $items.value
    } catch {
        Write-Log "Erro ao obter itens do SharePoint: $_"
        return $null
    }
}


# Variáveis para monitorar total de arquivos e volume de dados
$totalFilesTransferred = 0
$totalDataTransferredBytes = 0
$totalFilesWithErrors = 0 # Contador para arquivos com problemas
$totalFilesIgnored = 0    # Contador para arquivos ignorados

# Função para fazer o upload direto do arquivo do SharePoint para o OneDrive
function Upload-ToOneDrive {
    param (
        [string]$fileId,        # ID do arquivo no SharePoint
        [string]$fileName,      # Nome do arquivo no SharePoint
        [string]$destinationPath # Caminho de destino no OneDrive
    )

    Write-Log "Iniciando upload direto do arquivo '$fileName' para o OneDrive ($destinationPath)"
    
    # URL para acessar o conteúdo do arquivo no SharePoint
    $downloadUrl = "https://graph.microsoft.com/v1.0/sites/$siteId/drive/items/$fileId/content"
    $accessToken = Get-AccessToken
    $headers = @{ "Authorization" = "Bearer $accessToken" }

    try {
        # Obtém o conteúdo do arquivo do SharePoint como um array de bytes
        $response = Invoke-WebRequest -Method Get -Uri $downloadUrl -Headers $headers -ErrorAction Stop
        $fileContent = $response.Content

        if ($null -eq $fileContent) {
            Write-Log "Erro: Não foi possível obter o conteúdo do arquivo '$fileName' no SharePoint."
            $global:totalFilesWithErrors++ # Incrementa contador de erros
            return
        }

        # URL para upload no OneDrive
        $uploadUrl = "https://graph.microsoft.com/v1.0/users/$oneDriveUser/drive/root:/${destinationPath}:/content"

        # Realiza o upload diretamente usando o conteúdo do arquivo
        Invoke-RestMethod -Method PUT -Uri $uploadUrl -Headers $headers -Body $fileContent -ContentType "application/octet-stream"

        # Atualiza contadores
        $global:totalFilesTransferred++
        $global:totalDataTransferredBytes += $fileContent.Length

        Write-Log "Upload do arquivo '$fileName' para o OneDrive concluído com sucesso."
    } catch {
        Write-Log "Erro ao enviar o arquivo '$fileName' para o OneDrive: $_"
        $global:totalFilesWithErrors++ # Incrementa contador de erros
    }
}

# Função para comparar o tamanho de arquivos no SharePoint e no OneDrive
function Compare-FileSize {
    param (
        [string]$fileId,
        [string]$oneDriveDestination,
        [string]$sharePointFilePath
    )

    $accessToken = Get-AccessToken
    $sharePointFileUrl = "https://graph.microsoft.com/v1.0/sites/$siteId/drive/items/$fileId"
    $oneDriveFileUrl = "https://graph.microsoft.com/v1.0/users/$oneDriveUser/drive/root:/$oneDriveDestination"

    try {
        # Obter detalhes do arquivo no SharePoint
        $headers = @{ "Authorization" = "Bearer $accessToken" }
        $sharePointFile = Invoke-RestMethod -Method Get -Uri $sharePointFileUrl -Headers $headers
        $sharePointFileSize = $sharePointFile.size

        # Obter detalhes do arquivo no OneDrive
        $oneDriveFile = Invoke-RestMethod -Method Get -Uri $oneDriveFileUrl -Headers $headers -ErrorAction Stop
        $oneDriveFileSize = $oneDriveFile.size

        Write-Log "Comparando Origem com destino ......."
        Write-Log "Origem  em SharePoint - $sharePointFilePath (Tamanho: $sharePointFileSize bytes)"
        Write-Log "Destino em OneDrive   - $oneDriveDestination (Tamanho: $oneDriveFileSize bytes)"

        return $sharePointFileSize -eq $oneDriveFileSize
    } catch {
        # Suprimir erro de arquivo não encontrado e registrar a informação
        if ($_.Exception.Message -like "*404*") {
            Write-Log "Arquivo não encontrado no OneDrive para o caminho: $oneDriveDestination. Prosseguindo com o upload."
            return $false
        }
        Write-Log "Erro ao comparar tamanhos: $_"
        $global:totalFilesWithErrors++ # Incrementa contador de erros
        return $false
    }
}

# Função principal para migrar arquivos e pastas recursivamente
function Start-Migration {
    param (
        [string]$folderPath = "",
        [string]$oneDriveBaseDestination = ""
    )

    Write-Log "Processando a pasta: $folderPath"
    $items = Get-SharePointItems -folderPath $folderPath

    if ($items) {
        foreach ($item in $items) {
            if ($item.folder) {
                # Criar caminho de destino no OneDrive para a subpasta
                $subfolderDestination = "$oneDriveBaseDestination/$($item.name)"
                # Chamar recursivamente para explorar a subpasta
                Start-Migration -folderPath "$folderPath/$($item.name)" -oneDriveBaseDestination $subfolderDestination
            } elseif ($item.file) {
                # Criar caminho de destino no OneDrive
                $oneDriveDestination = "$oneDriveBaseDestination/$($item.name)"
                
                # O caminho completo do arquivo no SharePoint
                $sharePointFilePath = "$folderPath/$($item.name)"
                
                # Comparar o tamanho dos arquivos
                $filesMatch = Compare-FileSize -fileId $item.id -oneDriveDestination $oneDriveDestination -sharePointFilePath $sharePointFilePath

                if (-not $filesMatch) {
                    Write-Log "Os arquivos são diferentes. Iniciando upload do arquivo '$($item.name)' para o OneDrive."
                    Upload-ToOneDrive -fileId $item.id -fileName $item.name -destinationPath $oneDriveDestination
                } else {
                    Write-Log "O arquivo '$($item.name)' já existe no OneDrive e é idêntico."
                    $global:totalFilesIgnored++ # Incrementa contador de arquivos ignorados
                }
            } else {
                Write-Log "Item desconhecido: $($item | ConvertTo-Json -Depth 10)"
                $global:totalFilesWithErrors++ # Incrementa contador de erros em caso de item desconhecido
            }
        }
    } else {
        Write-Log "Nenhum item encontrado em: $folderPath"
    }
}

# Função para gerar o relatório final da migração
function Generate-MigrationReport {
    $totalDataTransferredGB = [math]::Round($global:totalDataTransferredBytes / 1GB, 2) # Convertendo bytes para gigabytes
    Write-Log "Migração concluída."
    Write-Log "Total de arquivos transferidos: $global:totalFilesTransferred"
    Write-Log "Total de arquivos ignorados: $global:totalFilesIgnored"
    Write-Log "Total de arquivos com erros: $global:totalFilesWithErrors"
    Write-Log "Volume total de dados transferidos: $totalDataTransferredGB GB"
}

# Obter o Site ID
Write-Log "Solicitando token e SiteID para: $domain/sites/$siteName"
$accessToken = Get-AccessToken
$siteId = Get-SiteId -accessToken $accessToken -domain $domain -siteName $siteName

if ($siteId) {
    Write-Log "Site ID obtido: $siteId"
    
    # Iniciar a migração 
    Start-Migration -folderPath $sourceFolderPath -oneDriveBaseDestination $oneDriveBaseDestination

    Generate-MigrationReport # Chamar a função para gerar o relatório final
} else {
    Write-Log "Falha ao obter o Site ID."
}


