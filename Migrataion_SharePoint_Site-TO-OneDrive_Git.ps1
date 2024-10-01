<# Script para permitir a migração de SharePoint Site para Onedrive de usuário - By Anderson Cardoso - 09/2024

####Pontos de atenção####
Testado em powershell 7.4, não roda em Powershell 5.X
É necessário registrar um APP no Portal Azure conforme documentação Readme.pdf
Após terminar o processo de migração, ele mantem a estrutura de pastas em c:\temp de forma proposital, pois se contiver algum arquivo
que não pode ser migrado ele ficará na estrutura;
Um log de execução é gerado em c:\temp para verificar todo o processo.


###Recursos####
Autenticação baseada em Token, usa Client ID, Client Secret, e Tenant ID para autenticar em ambos SharePoint
Migra Pastas recursivamente do Sharepoint para Onedrive nuvem;

####Funcionamento####
Valida credenciais de acesso ao Site Sharepoint utilizando API do Microsoft Graph;
Conecta no Sharepoint e obtém a estrutura de arquivos e pastas;
No local de execução c:\temp, baixa arquivo o primeiro arquivo e checa se existe no destino Onedrive;
Se não existe ele faz upload para o Servidor Onedrive nuvem; se o arquivo existe e sofreu modificação ele copia o arquivo modificado;
Após upload para Onedrive, o arquivo local é removido do c:\temp, e de forma recursiva ele executa arquivo por arquivo


####Limitações####
Caso tenha problema ao obter token de acesso, recomendo que autentique com o usuário no Sharepoint via Broswer.
Na raiz do site Sharepoint, ele não migra os arquivos, precisam esta dentro de pastas.

#>

# Variáveis de autenticação
$tenantId = "751fkgg-34341-48kalja-a4c1-9aeeb9dce"    # Seu Tenant ID
$clientId = "37d6deed-7c24-4d20-8112-3ckfesadse41"      # Seu Client ID
$clientSecret = "JL58Q~khdhedheidjeidjeidsmasaisdeids" # Seu Client Secret
$downloadPath = "C:\temp"  # Caminho para salvar os arquivos baixados
$oneDriveUser = "usuario@dominio.com.br"  # Usuário OneDrive
$domain = "seudominio.sharepoint.com"  # Substitua pelo seu domínio do SharePoint
$siteName = "seusite"      # Substitua pelo nome do seu site no SharePoint

# Caminho do arquivo de log
$logPath = "C:\temp\MigrationSharePoint-To-OneDrive.log"

# Função para escrever no log
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Add-Content -Path $logPath -Value $logMessage
    Write-Host $logMessage
}

function Get-SiteId {
    param (
        [string]$accessToken,
        [string]$domain,   # O domínio do SharePoint (ex: 'seudominio.sharepoint.com')
        [string]$siteName  # O nome do site (ex: 'seusite')
    )

    # URL correta da API para obter o siteId
    $requestUrl = "https://graph.microsoft.com/v1.0/sites/${domain}:/sites/${siteName}"

    try {
        $response = Invoke-RestMethod -Method Get -Uri $requestUrl -Headers @{ Authorization = "Bearer $accessToken" }
        return $response.id
    } catch {
        Write-Host "Erro ao obter o siteId: $_"
        return $null
    }
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

Write-Log "Solicitando token de SiteID: $domain/sites/$siteName"
    $accessToken = Get-AccessToken

# Obter o Site ID
$siteId = Get-SiteId -accessToken $accessToken -domain $domain -siteName $siteName

if ($siteId) {
    Write-Host "Site ID obtido: $siteId"
} else {
    Write-Host "Falha ao obter o Site ID."
}

# Função para criar diretório se não existir
function Create-Directory {
    param (
        [string]$path
    )
    
    if (-not (Test-Path -Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
        Write-Log "Criada a pasta: $path"
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

# Função para comparar tamanho de arquivos
function Compare-FileSize {
    param (
        [string]$localFilePath,
        [string]$oneDriveFilePath
    )

    $accessToken = Get-AccessToken
    $requestUrl = "https://graph.microsoft.com/v1.0/users/$oneDriveUser/drive/root:/$oneDriveFilePath"

    try {
        $headers = @{ "Authorization" = "Bearer $accessToken" }
        $oneDriveFile = Invoke-RestMethod -Method Get -Uri $requestUrl -Headers $headers

        $localFileSize = (Get-Item $localFilePath).Length
        $oneDriveFileSize = $oneDriveFile.size

        Write-Log "Tamanho do arquivo local: $localFileSize bytes, tamanho do arquivo no OneDrive: $oneDriveFileSize bytes"

        return $localFileSize -eq $oneDriveFileSize
    } catch {
        if ($oneDriveFileSize -eq $null)
            { write-log "Arquivo '$oneDriveFilePath' não existe no destino do Onedrive, irei iniciar Upload"
              
             Pause
            } Else{   
                Write-Log "Erro ao comparar tamanho do arquivo '$localFilePath' com o arquivo '$oneDriveFilePath' no OneDrive: $_"
                return $
                    }
            }
        }
# Função para fazer o upload do arquivo para o OneDrive
function Upload-ToOneDrive {
    param (
        [string]$filePath,
        [string]$destinationPath
    )

    Write-Log "Iniciando upload de $filePath para OneDrive ($destinationPath)"
    
    # Carregar arquivo no OneDrive
    $uploadUrl = "https://graph.microsoft.com/v1.0/users/$oneDriveUser/drive/root:/${destinationPath}:/content"
    $accessToken = Get-AccessToken
    $headers = @{ "Authorization" = "Bearer $accessToken" }

    try {
        Invoke-RestMethod -Method Put -Uri $uploadUrl -Headers $headers -InFile $filePath
        Write-Log "Upload do arquivo '$filePath' para o OneDrive concluído com sucesso."
    } catch {
        Write-Log "Erro ao enviar o arquivo '$filePath' para o OneDrive: $_"
    }
}

# Função para baixar arquivos do SharePoint
function Download-File {
    param (
        [string]$fileName,
        [string]$fileId,
        [string]$destinationPath
    )

    $accessToken = Get-AccessToken

    if (-not $accessToken) {
        Write-Log "Token de acesso não obtido. Abortando download."
        return
    }

    $downloadUrl = "https://graph.microsoft.com/v1.0/sites/$siteId/drive/items/$fileId/content"

    try {
        $headers = @{ "Authorization" = "Bearer $accessToken" }
        Invoke-RestMethod -Method Get -Uri $downloadUrl -Headers $headers -OutFile $destinationPath
        Write-Log "Arquivo baixado: $destinationPath"
    } catch {
        Write-Log "Erro ao baixar o arquivo '$fileName': $_"
    }
}

# Função principal para migrar arquivos e pastas recursivamente
function Start-Migration {
    param (
        [string]$folderPath = ""
    )

    Write-Log "Processando a pasta: $folderPath"
    $items = Get-SharePointItems -folderPath $folderPath

    if ($items) {
        foreach ($item in $items) {
            if ($item.folder) {
                # Criar a pasta local
                $localFolderPath = Join-Path -Path $downloadPath -ChildPath (Join-Path -Path $folderPath -ChildPath $item.name)
                Create-Directory -path $localFolderPath

                # Chamar recursivamente para explorar a subpasta
                Start-Migration -folderPath "$folderPath/$($item.name)"
            } elseif ($item.file) {
                # Baixar arquivo
                $filePath = Join-Path -Path $downloadPath -ChildPath (Join-Path -Path $folderPath -ChildPath $item.name)
                if (-not (Test-Path -Path $filePath)) {
                    Download-File -fileName $item.name -fileId $item.id -destinationPath $filePath
                } else {
                    Write-Log "Arquivo já existe: $filePath"
                }

                # Criar caminho de destino no OneDrive
                $oneDriveDestination = "$folderPath/$($item.name)"

                # Comparar arquivos pelo tamanho em bytes
                $oneDriveFileExists = Compare-FileSize -localFilePath $filePath -oneDriveFilePath $oneDriveDestination
                if (-not $oneDriveFileExists) {
                    Upload-ToOneDrive -filePath $filePath -destinationPath $oneDriveDestination
                }

                # Remover o arquivo localmente após o upload
                Remove-Item -Path $filePath -Force
                Write-Log "Arquivo removido do local: $filePath"
            } else {
                Write-Log "Item desconhecido: $($item | ConvertTo-Json -Depth 10)"
            }
        }
    } else {
        Write-Log "Nenhum item encontrado em: $folderPath"
    }
}

# Iniciar a migração a partir da raiz
#Start-Migration -folderPath ""

# Iniciar a migração a partir da selecionada
Start-Migration -folderPath "Teste"