# kcd_colombia_platform
Plataforma del Clúster: ArgoCD App of Apps y add-ons para la demo de migración ECS → GitOps en EKS.

## Objetivo
Mostrar cómo un único manifiesto raíz (App of Apps) controla add-ons de plataforma y posteriormente equipos de aplicación agregan sus propios repos.

## Estructura
```
clusters/
	prod/
		root-app.yaml        # Application raíz (define path addons/)
projects/
	platform-project.yaml  # AppProject con reglas básicas
addons/
	argocd/argocd/application.yaml
	aws-load-balancer-controller/application.yaml
	external-dns/application.yaml
	(futuros: cert-manager, metrics-server, external-secrets, etc.)
```

## Flujo (bootstrap)
1. Instalar ArgoCD (helm).
2. Aplicar una sola vez el root: `kubectl apply -f clusters/prod/root-app.yaml`.
3. ArgoCD crea/sincroniza cada add-on según waves.
4. Agregar un nuevo add-on = nueva carpeta + Application manifest → ArgoCD lo despliega.

## Sync Waves usadas
-1 root
 0 argocd-self (auto-gestión opcional)
10 aws-load-balancer-controller
20 external-dns

## AppProject (platform)
Permite todas las fuentes y namespaces para simplificar la demo. Endurecer luego restringiendo `sourceRepos` y `destinations`.

## Próximos add-ons sugeridos
- cert-manager
- metrics-server
- external-secrets (ESO)
- kube-prometheus-stack
- kyverno / gatekeeper

## Notas
- Habilitar RBAC/OIDC refinado agregando roles en el AppProject.

## Comando rápido de estado
```
kubectl get applications.argoproj.io -n argocd
```

