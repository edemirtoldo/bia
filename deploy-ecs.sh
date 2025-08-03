#!/bin/bash

# Script de Deploy para ECS - Projeto BIA
# Versão: 1.0
# Autor: Amazon Q para Projeto BIA

set -e

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_ECR_REPO="703671905295.dkr.ecr.us-east-1.amazonaws.com/bia"
DEFAULT_CLUSTER="cluster-bia-alb"
DEFAULT_SERVICE="service-bia-alb"
DEFAULT_TASK_FAMILY="taks-def-bia-alb"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir help
show_help() {
    echo -e "${BLUE}=== Script de Deploy ECS - Projeto BIA ===${NC}"
    echo ""
    echo "DESCRIÇÃO:"
    echo "  Script para build e deploy da aplicação BIA no Amazon ECS"
    echo "  Cada imagem é taggeada com o hash do commit para permitir rollbacks"
    echo ""
    echo "USO:"
    echo "  $0 [OPÇÕES] COMANDO"
    echo ""
    echo "COMANDOS:"
    echo "  deploy          Executa build completo e deploy"
    echo "  build-only      Apenas faz build e push da imagem"
    echo "  deploy-only     Apenas faz deploy (usa última imagem)"
    echo "  rollback TAG    Faz rollback para uma tag específica"
    echo "  list-images     Lista as últimas 10 imagens no ECR"
    echo "  help            Exibe esta ajuda"
    echo ""
    echo "OPÇÕES:"
    echo "  -r, --region REGION        Região AWS (padrão: $DEFAULT_REGION)"
    echo "  -e, --ecr-repo REPO        Repositório ECR (padrão: 703671905295.dkr.ecr.us-east-1.amazonaws.com/bia)"
    echo "  -c, --cluster CLUSTER      Nome do cluster ECS (padrão: $DEFAULT_CLUSTER)"
    echo "  -s, --service SERVICE      Nome do serviço ECS (padrão: $DEFAULT_SERVICE)"
    echo "  -t, --task-family FAMILY   Família da task definition (padrão: $DEFAULT_TASK_FAMILY)"
    echo "  -f, --force                Força novo deployment mesmo sem mudanças"
    echo "  -v, --verbose              Modo verboso"
    echo "  -h, --help                 Exibe esta ajuda"
    echo ""
    echo "EXEMPLOS:"
    echo "  $0 deploy                                    # Deploy completo"
    echo "  $0 build-only                               # Apenas build"
    echo "  $0 rollback a1b2c3d                         # Rollback para commit a1b2c3d"
    echo "  $0 deploy -c meu-cluster -s meu-service     # Deploy com cluster/service customizado"
    echo "  $0 list-images                              # Lista imagens disponíveis"
    echo ""
    echo "NOTAS:"
    echo "  - O script usa os últimos 7 caracteres do commit hash como tag"
    echo "  - Cada deploy cria uma nova task definition"
    echo "  - As imagens antigas ficam disponíveis para rollback"
    echo "  - Certifique-se de ter as credenciais AWS configuradas"
    echo ""
}

# Função para logging
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} ${timestamp} - $message" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $message" >&2
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" >&2
            ;;
        "DEBUG")
            if [[ $VERBOSE == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} ${timestamp} - $message" >&2
            fi
            ;;
    esac
}

# Função para verificar dependências
check_dependencies() {
    log "INFO" "Verificando dependências..."
    
    local deps=("docker" "aws" "git" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            log "ERROR" "$dep não está instalado ou não está no PATH"
            exit 1
        fi
    done
    
    # Verificar se está em um repositório git
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log "ERROR" "Este diretório não é um repositório git"
        exit 1
    fi
    
    log "INFO" "Todas as dependências estão OK"
}

# Função para obter commit hash
get_commit_hash() {
    local commit_hash=$(git rev-parse HEAD | cut -c 1-7)
    echo $commit_hash
}

# Função para fazer login no ECR
ecr_login() {
    log "INFO" "Fazendo login no ECR..."
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REPO
    if [[ $? -eq 0 ]]; then
        log "INFO" "Login no ECR realizado com sucesso"
    else
        log "ERROR" "Falha no login do ECR"
        exit 1
    fi
}

# Função para build da imagem
build_image() {
    local commit_hash=$(get_commit_hash)
    local image_tag="$ECR_REPO:$commit_hash"
    local latest_tag="$ECR_REPO:latest"
    
    log "INFO" "Iniciando build da imagem..."
    log "INFO" "Commit hash: $commit_hash"
    log "INFO" "Image tag: $image_tag"
    
    # Build da imagem
    log "DEBUG" "Executando: docker build -t $latest_tag ."
    docker build -t $latest_tag .
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Build da imagem concluído com sucesso"
    else
        log "ERROR" "Falha no build da imagem"
        exit 1
    fi
    
    # Tag com commit hash
    log "DEBUG" "Executando: docker tag $latest_tag $image_tag"
    docker tag $latest_tag $image_tag
    
    # Push das imagens
    log "INFO" "Fazendo push das imagens para o ECR..."
    docker push $latest_tag
    docker push $image_tag
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Push das imagens concluído com sucesso"
        # Retornar apenas o commit hash, sem logs
        echo "$commit_hash"
    else
        log "ERROR" "Falha no push das imagens"
        exit 1
    fi
}

# Função para criar nova task definition
create_task_definition() {
    local image_tag=$1
    local image_uri="$ECR_REPO:$image_tag"
    
    log "INFO" "Criando nova task definition..."
    log "INFO" "Imagem: $image_uri"
    
    # Obter task definition atual
    local current_task_def=$(aws ecs describe-task-definition \
        --task-definition $TASK_FAMILY \
        --region $REGION \
        --query 'taskDefinition' \
        --output json)
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Falha ao obter task definition atual"
        exit 1
    fi
    
    log "DEBUG" "Task definition atual obtida com sucesso"
    
    # Atualizar a imagem na task definition e remover campos desnecessários
    local new_task_def=$(echo "$current_task_def" | jq --arg IMAGE_URI "$image_uri" '
        .containerDefinitions[0].image = $IMAGE_URI |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy, .enableFaultInjection)
    ')
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Falha ao processar task definition com jq"
        exit 1
    fi
    
    log "DEBUG" "Task definition processada com sucesso"
    
    # Salvar em arquivo temporário
    local temp_file="/tmp/new_task_def_$(date +%s).json"
    echo "$new_task_def" > "$temp_file"
    
    if [[ $VERBOSE == "true" ]]; then
        log "DEBUG" "Task definition salva em $temp_file"
    fi
    
    # Registrar nova task definition
    log "DEBUG" "Registrando nova task definition..."
    local new_revision=$(aws ecs register-task-definition \
        --region $REGION \
        --cli-input-json "file://$temp_file" \
        --query 'taskDefinition.revision' \
        --output text)
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Nova task definition criada: $TASK_FAMILY:$new_revision"
        # Limpar arquivo temporário
        rm -f "$temp_file"
        echo $new_revision
    else
        log "ERROR" "Falha ao criar nova task definition"
        if [[ $VERBOSE == "true" ]]; then
            log "DEBUG" "Verifique o arquivo $temp_file para debug"
        else
            rm -f "$temp_file"
        fi
        exit 1
    fi
}

# Função para fazer deploy
deploy_service() {
    local task_revision=$1
    local task_definition="$TASK_FAMILY:$task_revision"
    
    log "INFO" "Iniciando deploy do serviço..."
    log "INFO" "Task Definition: $task_definition"
    log "INFO" "Cluster: $CLUSTER"
    log "INFO" "Service: $SERVICE"
    
    local update_cmd="aws ecs update-service \
        --cluster $CLUSTER \
        --service $SERVICE \
        --task-definition $task_definition \
        --region $REGION"
    
    if [[ $FORCE_DEPLOYMENT == "true" ]]; then
        update_cmd="$update_cmd --force-new-deployment"
    fi
    
    log "DEBUG" "Executando: $update_cmd"
    eval $update_cmd > /dev/null
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Deploy iniciado com sucesso"
        log "INFO" "Aguardando estabilização do serviço..."
        
        aws ecs wait services-stable \
            --cluster $CLUSTER \
            --services $SERVICE \
            --region $REGION
        
        if [[ $? -eq 0 ]]; then
            log "INFO" "Deploy concluído com sucesso!"
        else
            log "WARN" "Deploy iniciado, mas houve timeout na estabilização"
        fi
    else
        log "ERROR" "Falha no deploy do serviço"
        exit 1
    fi
}

# Função para listar imagens
list_images() {
    log "INFO" "Listando últimas 10 imagens no ECR..."
    
    local repo_name=$(echo $ECR_REPO | cut -d'/' -f2)
    
    aws ecr describe-images \
        --repository-name $repo_name \
        --region $REGION \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
        --output table
}

# Função para rollback
rollback() {
    local target_tag=$1
    
    if [[ -z $target_tag ]]; then
        log "ERROR" "Tag para rollback não especificada"
        exit 1
    fi
    
    log "INFO" "Iniciando rollback para tag: $target_tag"
    
    # Verificar se a imagem existe
    local image_exists=$(aws ecr describe-images \
        --repository-name $(echo $ECR_REPO | cut -d'/' -f2) \
        --image-ids imageTag=$target_tag \
        --region $REGION \
        --query 'imageDetails[0].imageTags[0]' \
        --output text 2>/dev/null)
    
    if [[ $image_exists == "None" ]] || [[ -z $image_exists ]]; then
        log "ERROR" "Imagem com tag '$target_tag' não encontrada no ECR"
        log "INFO" "Use '$0 list-images' para ver as imagens disponíveis"
        exit 1
    fi
    
    # Criar nova task definition com a imagem de rollback
    local new_revision=$(create_task_definition $target_tag)
    
    # Fazer deploy
    deploy_service $new_revision
    
    log "INFO" "Rollback para tag '$target_tag' concluído!"
}

# Função principal de deploy
full_deploy() {
    check_dependencies
    ecr_login
    
    # Capturar apenas a última linha (commit hash) do build
    local build_output=$(build_image)
    local commit_hash=$(echo "$build_output" | tail -n 1)
    
    log "DEBUG" "Commit hash capturado: $commit_hash"
    
    local new_revision=$(create_task_definition $commit_hash)
    deploy_service $new_revision
    
    log "INFO" "Deploy completo finalizado!"
    log "INFO" "Commit hash: $commit_hash"
    log "INFO" "Task Definition: $TASK_FAMILY:$new_revision"
}

# Função para build apenas
build_only() {
    check_dependencies
    ecr_login
    
    local build_output=$(build_image)
    local commit_hash=$(echo "$build_output" | tail -n 1)
    
    log "INFO" "Build concluído! Tag da imagem: $commit_hash"
}

# Função para deploy apenas
deploy_only() {
    check_dependencies
    
    local commit_hash=$(get_commit_hash)
    local new_revision=$(create_task_definition $commit_hash)
    deploy_service $new_revision
    
    log "INFO" "Deploy concluído usando imagem existente: $commit_hash"
}

# Parsing dos argumentos
REGION=$DEFAULT_REGION
ECR_REPO=$DEFAULT_ECR_REPO
CLUSTER=$DEFAULT_CLUSTER
SERVICE=$DEFAULT_SERVICE
TASK_FAMILY=$DEFAULT_TASK_FAMILY
FORCE_DEPLOYMENT="false"
VERBOSE="false"
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -t|--task-family)
            TASK_FAMILY="$2"
            shift 2
            ;;
        -f|--force)
            FORCE_DEPLOYMENT="true"
            shift
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        deploy|build-only|deploy-only|list-images|help)
            COMMAND="$1"
            shift
            ;;
        rollback)
            COMMAND="$1"
            ROLLBACK_TAG="$2"
            shift 2
            ;;
        *)
            log "ERROR" "Opção desconhecida: $1"
            echo "Use '$0 help' para ver as opções disponíveis"
            exit 1
            ;;
    esac
done

# Verificar se comando foi especificado
if [[ -z $COMMAND ]]; then
    log "ERROR" "Nenhum comando especificado"
    echo "Use '$0 help' para ver os comandos disponíveis"
    exit 1
fi

# Executar comando
case $COMMAND in
    "deploy")
        full_deploy
        ;;
    "build-only")
        build_only
        ;;
    "deploy-only")
        deploy_only
        ;;
    "rollback")
        rollback $ROLLBACK_TAG
        ;;
    "list-images")
        list_images
        ;;
    "help")
        show_help
        ;;
    *)
        log "ERROR" "Comando inválido: $COMMAND"
        exit 1
        ;;
esac
