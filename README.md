# ToggleMaster — ambiente local

Este repositório-raiz reúne os cinco microsserviços do ToggleMaster para execução **100% local**, antes do provisionamento AWS. Nenhum recurso, credencial ou custo AWS real é necessário nesta etapa.

## Arquitetura validada

```text
Cliente → evaluation-service → flag-service / targeting-service
                 │                    │              │
               Redis              PostgreSQL     PostgreSQL
                 │
                 └→ SQS (LocalStack) → analytics-service → DynamoDB (LocalStack)
```

São nove contêineres: cinco aplicações, dois PostgreSQL, Redis e LocalStack (SQS + DynamoDB).

| Serviço | Porta local |
|---|---:|
| auth-service | 8001 |
| flag-service | 8002 |
| targeting-service | 8003 |
| evaluation-service | 8004 |
| analytics-service | 8005 |
| PostgreSQL auth | 5432 |
| PostgreSQL de configuração | 5433 |
| Redis | 6379 |
| LocalStack | 4566 |

## Estrutura esperada

```text
root/
├── docker-compose.yml
├── .env
├── .env.example
├── infra/postgres-config/init.sql
├── auth-service/
├── flag-service/
│   └── db/init.sql
├── targeting-service/
│   └── db/init.sql
├── evaluation-service/
└── analytics-service/
```

Cada serviço deve possuir seu próprio `Dockerfile` e `.dockerignore`.

## Pré-requisitos

- Docker Desktop com backend WSL 2;
- Docker Compose v2;
- AWS CLI v2 (usada somente contra o LocalStack nesta etapa);
- `curl` ou Postman.


## Validação das ferramentas locais

Antes de criar contêineres, confirme que todas as ferramentas usadas neste ambiente estão disponíveis no terminal:

```bat
docker --version
docker compose version
aws --version
git --version
curl --version
```

Resultados esperados:

- `docker` e `docker compose`: versões instaladas pelo Docker Desktop;
- `aws`: AWS CLI v2;
- `git`: cliente Git disponível para obter e versionar os serviços;
- `curl`: cliente HTTP usado nos health checks e testes das APIs.

O Go e o Python não precisam estar instalados na máquina host para esta etapa: a compilação e a execução ocorrem dentro das imagens Docker.

## Variáveis locais

Crie `.env` na mesma pasta do `docker-compose.yml`:

```dotenv
AUTH_DB_PASSWORD=auth_local_2026
CONFIG_DB_PASSWORD=config_local_2026
MASTER_KEY=master_local_2026
SERVICE_API_KEY=temporaria

AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_ENDPOINT_URL=http://localstack:4566
AWS_SQS_URL=http://localstack:4566/000000000000/togglemaster-events
AWS_DYNAMODB_ENDPOINT=http://localstack:4566
AWS_DYNAMODB_TABLE=ToggleMasterAnalytics
```

Não versione `.env`. Mantenha no Git apenas `.env.example`, com os mesmos nomes e **valores vazios** para os segredos.

> As credenciais `test` são fictícias. Elas existem somente porque os SDKs AWS exigem valores, mesmo quando o destino é o LocalStack.

## PostgreSQL compartilhado

O `postgres-config` contém dois bancos logicamente separados: `flags_db` e `targeting_db`.

Crie `infra/postgres-config/init.sql`:

```sql
CREATE DATABASE flags_db;
CREATE DATABASE targeting_db;

\connect flags_db
\i /opt/togglemaster/flags.sql

\connect targeting_db
\i /opt/togglemaster/targeting.sql
```

No Compose, monte também os schemas dos serviços:

```yaml
volumes:
  - ./infra/postgres-config/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
  - ./flag-service/db/init.sql:/opt/togglemaster/flags.sql:ro
  - ./targeting-service/db/init.sql:/opt/togglemaster/targeting.sql:ro
```

Os scripts em `/docker-entrypoint-initdb.d` são executados **apenas na primeira criação do volume**. Após alterar esses scripts durante testes, recrie o volume do PostgreSQL ou crie os bancos manualmente.

## LocalStack

Use LocalStack no lugar de um contêiner isolado de DynamoDB, pois ele fornece simultaneamente SQS e DynamoDB:

```yaml
localstack:
  image: localstack/localstack:3.8
  environment:
    SERVICES: sqs,dynamodb
    AWS_DEFAULT_REGION: us-east-1
  ports:
    - "4566:4566"
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
```

Nos contêineres `evaluation-service` e `analytics-service`, use `http://localstack:4566`, nunca `localhost:4566`. `localhost` dentro de um contêiner é o próprio contêiner.

## Ajustes necessários no código

### `evaluation-service` (Go)

O cliente SQS deve respeitar `AWS_ENDPOINT_URL`:

```go
awsEndpointURL := os.Getenv("AWS_ENDPOINT_URL")
awsConfig := &aws.Config{Region: aws.String(awsRegion)}

if awsEndpointURL != "" {
    awsConfig.Endpoint = aws.String(awsEndpointURL)
}

sess, err := session.NewSession(awsConfig)
sqsSvc = sqs.New(sess)
```

Sem `AWS_ENDPOINT_URL`, o mesmo código usa a AWS real, como será necessário posteriormente.

### `analytics-service` (Python)

Crie ambos os clientes Boto3 com o endpoint opcional:

```python
AWS_ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL")
session = boto3.Session(region_name=AWS_REGION)

sqs_client = session.client("sqs", endpoint_url=AWS_ENDPOINT_URL or None)
dynamodb_client = session.client("dynamodb", endpoint_url=AWS_ENDPOINT_URL or None)
```

Se faltar esse ajuste, o log exibirá `InvalidClientTokenId`, pois o processo tentará consultar a AWS real.

## Subir o ambiente

```bat
docker compose up -d --build
docker compose ps
```

Os cinco endpoints devem responder `{"status":"ok"}`:

```bat
curl http://localhost:8001/health
curl http://localhost:8002/health
curl http://localhost:8003/health
curl http://localhost:8004/health
curl http://localhost:8005/health
```

## Criar recursos no LocalStack

No CMD, defina credenciais temporárias fictícias para evitar que a CLI use credenciais AWS reais:

```bat
set AWS_ACCESS_KEY_ID=test
set AWS_SECRET_ACCESS_KEY=test
set AWS_DEFAULT_REGION=us-east-1
```

Crie a fila e a tabela:

```bat
aws sqs create-queue --queue-name togglemaster-events --endpoint-url http://localhost:4566

aws dynamodb create-table --table-name ToggleMasterAnalytics --attribute-definitions AttributeName=event_id,AttributeType=S --key-schema AttributeName=event_id,KeyType=HASH --billing-mode PAY_PER_REQUEST --endpoint-url http://localhost:4566
```

Confira:

```bat
aws sqs list-queues --endpoint-url http://localhost:4566
aws dynamodb list-tables --endpoint-url http://localhost:4566
```

## Validar o fluxo ponta a ponta

### 1. Criar a chave interna

Quando o `auth-service` estiver saudável, crie a chave que será usada pelo `evaluation-service` para consultar flag e targeting:

```bat
curl -X POST http://localhost:8001/admin/keys ^
  -H "Content-Type: application/json" ^
  -H "Authorization: Bearer master_local_2026" ^
  -d "{\"name\":\"evaluation-service\"}"
```

Copie a chave retornada para `SERVICE_API_KEY` no `.env` e recrie o serviço:

```bat
docker compose up -d --force-recreate evaluation-service
```

### 2. Criar uma flag habilitada

```bat
curl -X POST http://localhost:8002/flags ^
  -H "Content-Type: application/json" ^
  -H "Authorization: Bearer SUA_SERVICE_API_KEY" ^
  -d "{\"name\":\"checkout_novo\",\"description\":\"Teste local do fluxo\",\"is_enabled\":true}"
```

### 3. Executar uma avaliação

O endpoint é `GET` e recebe parâmetros de query string, não JSON:

```bat
curl "http://localhost:8004/evaluate?user_id=lucas-001&flag_name=checkout_novo"
```

Resultado esperado:

```json
{"flag_name":"checkout_novo","user_id":"lucas-001","result":true}
```

### 4. Confirmar o consumo e a persistência

```bat
docker compose logs -f evaluation-service analytics-service

aws dynamodb scan --table-name ToggleMasterAnalytics --endpoint-url http://localhost:4566
```

O registro no DynamoDB deve conter `event_id`, `user_id`, `flag_name`, `result` e `timestamp`.

## Diagnóstico rápido

| Sintoma | Causa e correção |
|---|---|
| `pkg_resources` ausente ao iniciar Gunicorn | Fixe `setuptools==80.9.0` no estágio de build dos três serviços Python e reconstrua sem cache. |
| `database flags_db/targeting_db does not exist` | O volume foi iniciado sem os scripts. Crie os bancos/aplique schemas ou recrie o volume local. |
| `InvalidClientTokenId` no analytics | O cliente Boto3 não recebeu `endpoint_url` ou `AWS_ENDPOINT_URL` não chegou ao contêiner. |
| CLI não conecta em `localhost:4566` | LocalStack não está em execução ou a porta `4566:4566` não foi publicada. |

## Limpeza

Para parar sem apagar dados:

```bat
docker compose down
```

Para reiniciar o ambiente totalmente — incluindo bancos, Redis e dados locais:

```bat
docker compose down --volumes
```

## Próxima fase

Após esta validação local, iniciar a implantação AWS real: publicar imagens no ECR, criar EKS, RDS, ElastiCache, SQS e DynamoDB, e então adaptar as variáveis para os endpoints reais. Não reutilize as credenciais fictícias do LocalStack na AWS.
