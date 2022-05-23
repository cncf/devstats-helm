./scripts/deploy_backup_to_prod.sh kubernetes 0 1
./scripts/deploy_backup_to_prod.sh prometheus 1 2
# ./scripts/deploy_backup_to_prod.sh opentracing 2 3
./scripts/deploy_backup_to_prod.sh fluentd 3 4
./scripts/deploy_backup_to_prod.sh linkerd 4 5
./scripts/deploy_backup_to_prod.sh grpc 5 6
./scripts/deploy_backup_to_prod.sh coredns 6 7
./scripts/deploy_backup_to_prod.sh containerd 7 8
# ./scripts/deploy_backup_to_prod.sh rkt 8 9
./scripts/deploy_backup_to_prod.sh cni 9 10
./scripts/deploy_backup_to_prod.sh envoy 10 11
./scripts/deploy_backup_to_prod.sh jaeger 11 12
./scripts/deploy_backup_to_prod.sh notary 12 13
./scripts/deploy_backup_to_prod.sh tuf 13 14
./scripts/deploy_backup_to_prod.sh rook 14 15
./scripts/deploy_backup_to_prod.sh vitess 15 16
./scripts/deploy_backup_to_prod.sh nats 16 17
./scripts/deploy_backup_to_prod.sh opa 17 18
./scripts/deploy_backup_to_prod.sh spiffe 18 19
./scripts/deploy_backup_to_prod.sh spire 19 20
./scripts/deploy_backup_to_prod.sh cloudevents 20 21
./scripts/deploy_backup_to_prod.sh telepresence 21 22
./scripts/deploy_backup_to_prod.sh helm 22 23
./scripts/deploy_backup_to_prod.sh openmetrics 23 24
./scripts/deploy_backup_to_prod.sh harbor 24 25
./scripts/deploy_backup_to_prod.sh etcd 25 26
./scripts/deploy_backup_to_prod.sh tikv 26 27
./scripts/deploy_backup_to_prod.sh cortex 27 28
./scripts/deploy_backup_to_prod.sh buildpacks 28 29
./scripts/deploy_backup_to_prod.sh falco 29 30
./scripts/deploy_backup_to_prod.sh dragonfly 30 31
./scripts/deploy_backup_to_prod.sh virtualkubelet 31 32
./scripts/deploy_backup_to_prod.sh kubeedge 32 33
./scripts/deploy_backup_to_prod.sh brigade 33 34
./scripts/deploy_backup_to_prod.sh crio 34 35
./scripts/deploy_backup_to_prod.sh networkservicemesh 35 36
./scripts/deploy_backup_to_prod.sh openebs 36 37
./scripts/deploy_backup_to_prod.sh opentelemetry 37 38
# special
./scripts/deploy_backup_to_prod.sh all 38 39
./scripts/deploy_backup_to_prod.sh tekton 39 40
./scripts/deploy_backup_to_prod.sh spinnaker 40 41
./scripts/deploy_backup_to_prod.sh jenkinsx 41 42
./scripts/deploy_backup_to_prod.sh jenkins 42 43
./scripts/deploy_backup_to_prod.sh allcdf 43 44
./scripts/deploy_backup_to_prod.sh graphqljs 44 45
./scripts/deploy_backup_to_prod.sh graphiql 45 46
./scripts/deploy_backup_to_prod.sh graphqlspec 46 47
./scripts/deploy_backup_to_prod.sh expressgraphql 47 48
./scripts/deploy_backup_to_prod.sh graphql 48 49
#./scripts/deploy_backup_to_prod.sh cncf 49 50
#./scripts/deploy_backup_to_prod.sh opencontainers 50 51
#./scripts/deploy_backup_to_prod.sh istio 51 52
#./scripts/deploy_backup_to_prod.sh knative 52 53
#./scripts/deploy_backup_to_prod.sh zephyr 53 54
#./scripts/deploy_backup_to_prod.sh linux 54 55

./scripts/deploy_backup_to_prod.sh thanos 55 56
./scripts/deploy_backup_to_prod.sh flux 56 57
./scripts/deploy_backup_to_prod.sh intoto 57 58
./scripts/deploy_backup_to_prod.sh strimzi 58 59
# special
#./scripts/deploy_backup_to_prod.sh sam 59 60
#./scripts/deploy_backup_to_prod.sh azf 60 61
#./scripts/deploy_backup_to_prod.sh riff 61 62
#./scripts/deploy_backup_to_prod.sh fn 62 63
#./scripts/deploy_backup_to_prod.sh openwhisk 63 64
#./scripts/deploy_backup_to_prod.sh openfaas 64 65

./scripts/deploy_backup_to_prod.sh kubevirt 65 66
./scripts/deploy_backup_to_prod.sh longhorn 66 67
# special
#./scripts/deploy_backup_to_prod.sh cii 67 68
#./scripts/deploy_backup_to_prod.sh prestodb 68 69

./scripts/deploy_backup_to_prod.sh chubaofs 69 70
./scripts/deploy_backup_to_prod.sh keda 70 71
./scripts/deploy_backup_to_prod.sh smi 71 72
./scripts/deploy_backup_to_prod.sh argo 72 73
./scripts/deploy_backup_to_prod.sh volcano 73 74
./scripts/deploy_backup_to_prod.sh cnigenie 74 75
./scripts/deploy_backup_to_prod.sh keptn 75 76
./scripts/deploy_backup_to_prod.sh kudo 76 77
./scripts/deploy_backup_to_prod.sh cloudcustodian 77 78
./scripts/deploy_backup_to_prod.sh dex 78 79
./scripts/deploy_backup_to_prod.sh litmuschaos 79 80
./scripts/deploy_backup_to_prod.sh artifacthub 80 81
./scripts/deploy_backup_to_prod.sh kuma 81 82
./scripts/deploy_backup_to_prod.sh parsec 82 83
./scripts/deploy_backup_to_prod.sh bfe 83 84
./scripts/deploy_backup_to_prod.sh crossplane 84 85
./scripts/deploy_backup_to_prod.sh contour 85 86
./scripts/deploy_backup_to_prod.sh operatorframework 86 87
./scripts/deploy_backup_to_prod.sh chaosmesh 87 88
./scripts/deploy_backup_to_prod.sh serverlessworkflow 88 89
./scripts/deploy_backup_to_prod.sh k3s 89 90
./scripts/deploy_backup_to_prod.sh backstage 90 91
./scripts/deploy_backup_to_prod.sh tremor 91 92
./scripts/deploy_backup_to_prod.sh metal3 92 93
./scripts/deploy_backup_to_prod.sh porter 93 94
./scripts/deploy_backup_to_prod.sh openyurt 94 95
./scripts/deploy_backup_to_prod.sh openservicemesh 95 96
./scripts/deploy_backup_to_prod.sh keylime 96 97

# special
#./scripts/deploy_backup_to_prod.sh godotengine 97 98

./scripts/deploy_backup_to_prod.sh schemahero 98 99
./scripts/deploy_backup_to_prod.sh cdk8s 99 100
./scripts/deploy_backup_to_prod.sh certmanager 100 101
./scripts/deploy_backup_to_prod.sh openkruise 101 102
./scripts/deploy_backup_to_prod.sh tinkerbell 102 103
./scripts/deploy_backup_to_prod.sh pravega 103 104
./scripts/deploy_backup_to_prod.sh kyverno 104 105
