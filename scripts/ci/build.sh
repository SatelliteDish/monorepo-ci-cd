json="$(./scripts/ci/changed.sh dfaedff 07a338e)"

# Loop over workspace members
while read member; do
  name="$(echo "$member" | jq -r '.name')"
  path="$(echo "$member" | jq -r '.path')"
  changed="$(echo "$member" | jq -r '.changed')"

  echo "$name is $changed"
  if [[ "$changed" = "true" ]]; then
    echo "BUILDING AT $path"
    pnpm -C "$path" run deploy 1>/dev/null
    rc=$?

    if [ "$rc" -ne "0" ]; then
      echo "Failed to deploy $name"
      echo "RC: $rc"
      exit 1
    fi
  fi

done < <(echo "$json" | jq -c '.[]')

