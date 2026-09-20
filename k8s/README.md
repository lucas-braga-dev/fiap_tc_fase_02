# ToggleMaster no Kubernetes local

Estes manifests reproduzem no Kubernetes o ambiente já validado com Docker
Compose. Eles não dependem de EKS, ECR, RDS, ElastiCache ou de credenciais AWS
reais.

## Estrutura

```text
k8s/
├── base/
│   ├── applications/       # Deployments e Services dos cinco microsserviços
│   ├── configmaps/         # URLs internas e scripts SQL
│   ├── infrastructure/     # PostgreSQL, Redis, LocalStack e bootstrap
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   └── serviceaccounts.yaml
├── autoscaling/            # HPA e KEDA, aplicados somente na segunda etapa
└── secrets/
    └── togglemaster-secrets.example.yaml
```

A base executa nove Pods de longa duração: cinco aplicações, dois PostgreSQL,
Redis e LocalStack. O Job `localstack-bootstrap` cria a fila SQS e a tabela
DynamoDB locais.

## 1. Validar sem possuir cluster

O `kubectl kustomize` é executado localmente e não precisa de contexto ativo:

```bat
kubectl kustomize k8s\base > NUL
kubectl kustomize k8s\autoscaling > NUL
```

Esses comandos validam a composição dos arquivos. Eles não comprovam que os
containers iniciam nem que as APIs adicionais do KEDA estão instaladas.

## 2. Preparar as imagens

Na raiz do repositório:

```bat
docker compose build
docker image ls "togglemaster/*"
```

As imagens esperadas são:

```text
togglemaster/auth-service:local
togglemaster/flag-service:local
togglemaster/targeting-service:local
togglemaster/evaluation-service:local
togglemaster/analytics-service:local
```

Em um cluster criado pelo `kind`, carregue-as explicitamente:

```bat
kind load docker-image ^
  togglemaster/auth-service:local ^
  togglemaster/flag-service:local ^
  togglemaster/targeting-service:local ^
  togglemaster/evaluation-service:local ^
  togglemaster/analytics-service:local ^
  --name togglemaster
```

Os Deployments usam `imagePullPolicy: IfNotPresent`, portanto o Kubernetes não
tentará baixar essas imagens locais quando elas já estiverem no nó.

## 3. Criar o Secret local

Copie o modelo:

```bat
copy k8s\secrets\togglemaster-secrets.example.yaml k8s\secrets\togglemaster-secrets.yaml
```

Edite os valores de:

- `AUTH_DB_PASSWORD`;
- `CONFIG_DB_PASSWORD`;
- `MASTER_KEY`;
- `SERVICE_API_KEY`.

Mantenha as credenciais fictícias do LocalStack como `test`. O arquivo criado
está no `.gitignore` e não deve ser versionado.

Na primeira implantação, `SERVICE_API_KEY` pode continuar com um valor
temporário. A chave definitiva será criada pelo `auth-service` posteriormente.

## 4. Aplicar a base quando houver um cluster

Confirme primeiro o contexto, para evitar aplicar no cluster errado:

```bat
kubectl config current-context
kubectl get nodes
```

Crie o namespace e o Secret antes dos workloads:

```bat
kubectl apply -f k8s\base\namespace.yaml
kubectl apply -f k8s\secrets\togglemaster-secrets.yaml
kubectl apply -k k8s\base
```

Acompanhe a inicialização:

```bat
kubectl get pods -n togglemaster -w
```

Em outro terminal, espere o bootstrap do LocalStack:

```bat
kubectl wait -n togglemaster --for=condition=complete job/localstack-bootstrap --timeout=10m
```

Confira os recursos:

```bat
kubectl get deployments,statefulsets,services,pvc,jobs -n togglemaster
kubectl get pods -n togglemaster
```

Se algum Pod falhar:

```bat
kubectl describe pod -n togglemaster NOME_DO_POD
kubectl logs -n togglemaster NOME_DO_POD --all-containers
```

## 5. Acessar as APIs localmente

Os Services são `ClusterIP`. Abra cinco terminais e mantenha um comando em cada:

```bat
kubectl port-forward -n togglemaster service/auth-service 8001:8001
kubectl port-forward -n togglemaster service/flag-service 8002:8002
kubectl port-forward -n togglemaster service/targeting-service 8003:8003
kubectl port-forward -n togglemaster service/evaluation-service 8004:8004
kubectl port-forward -n togglemaster service/analytics-service 8005:8005
```

Valide:

```bat
curl http://localhost:8001/health
curl http://localhost:8002/health
curl http://localhost:8003/health
curl http://localhost:8004/health
curl http://localhost:8005/health
```

## 6. Criar a chave interna

Use o valor de `MASTER_KEY` salvo no Secret:

```bat
curl -X POST http://localhost:8001/admin/keys ^
  -H "Content-Type: application/json" ^
  -H "Authorization: Bearer SUA_MASTER_KEY" ^
  -d "{\"name\":\"evaluation-service\"}"
```

Copie a chave retornada para `SERVICE_API_KEY` em
`k8s\secrets\togglemaster-secrets.yaml` e aplique a mudança:

```bat
kubectl apply -f k8s\secrets\togglemaster-secrets.yaml
kubectl rollout restart deployment/evaluation-service -n togglemaster
kubectl rollout status deployment/evaluation-service -n togglemaster
```

## 7. Validar o fluxo completo

Crie uma flag:

```bat
curl -X POST http://localhost:8002/flags ^
  -H "Content-Type: application/json" ^
  -H "Authorization: Bearer SUA_SERVICE_API_KEY" ^
  -d "{\"name\":\"checkout_novo\",\"description\":\"Teste Kubernetes local\",\"is_enabled\":true}"
```

Execute uma avaliação:

```bat
curl "http://localhost:8004/evaluate?user_id=lucas-001&flag_name=checkout_novo"
```

Acompanhe o evento:

```bat
kubectl logs -n togglemaster deployment/evaluation-service -f
kubectl logs -n togglemaster deployment/analytics-service -f
```

Confirme a persistência no DynamoDB local:

```bat
kubectl exec -n togglemaster deployment/localstack -- ^
  awslocal dynamodb scan --table-name ToggleMasterAnalytics
```

## 8. Autoscaling opcional

Não aplique esta etapa antes de instalar o Metrics Server e o KEDA.

Metrics Server:

```bat
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server ^
  --namespace kube-system ^
  --set args[0]=--kubelet-insecure-tls
```

KEDA:

```bat
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install keda kedacore/keda ^
  --namespace keda ^
  --create-namespace
```

Espere ambos ficarem prontos e aplique os recursos:

```bat
kubectl rollout status deployment/metrics-server -n kube-system
kubectl rollout status deployment/keda-operator -n keda
kubectl apply -k k8s\autoscaling
```

Verifique:

```bat
kubectl get hpa -n togglemaster
kubectl get scaledobject,triggerauthentication -n togglemaster
kubectl top pods -n togglemaster
```

O `evaluation-service` escala por CPU, entre 1 e 5 réplicas. O
`analytics-service` escala entre 1 e 5 réplicas conforme a quantidade de
mensagens na fila `togglemaster-events`, considerando cinco mensagens por Pod.

## 9. Remover o ambiente

Para remover todo o namespace, incluindo Secrets e volumes persistentes:

```bat
kubectl delete namespace togglemaster
```

Esse comando apaga também os dados locais dos PostgreSQL, Redis e LocalStack.
