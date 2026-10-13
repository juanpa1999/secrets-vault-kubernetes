kubectl apply -f dp-db.yaml

sleep 5
# render tenant/vault URL placeholders from terraform outputs, then wait for ESO to create db-secret
eval "$(terraform output -raw apply_external_secret_command)"
kubectl wait externalsecret/db-secret --for=condition=Ready --timeout=60s
kubectl apply -f dp-back.yaml


sleep 2

kubectl apply -f dp-front.yaml

sleep 5

# wait until Postgres accepts connections, otherwise alembic/seed fail on a cold start
until kubectl exec deploy/db-deployment -- pg_isready -U postgres -d postgres > /dev/null 2>&1; do
  echo "waiting for db..."
  sleep 2
done

kubectl exec -it $(kubectl get pods -l app=back -o jsonpath="{.items[0].metadata.name}") -- alembic upgrade head

# seed test data (user pablodevops, sensors, readings); needs the tables created by alembic above
kubectl exec -i deploy/db-deployment -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql

# port-forward back (8000) and front (3000) to localhost; Ctrl+C stops both
kubectl port-forward svc/back-service 8000:8000 &
BACK_PF_PID=$!
kubectl port-forward svc/front-service 3000:3000 &
FRONT_PF_PID=$!
trap 'kill $BACK_PF_PID $FRONT_PF_PID 2>/dev/null' INT TERM EXIT
echo "back:  http://localhost:8000"
echo "front: http://localhost:3000"
wait


#user: pablodevops pass: Test123456789*