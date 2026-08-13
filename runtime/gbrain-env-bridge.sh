#!/usr/bin/env bash

# Least-privilege GBrain env bridge.
# /data/.env is parsed as data; it is never sourced or evaluated.

_gbrain_env_file=/data/.env

if [[ -r "$_gbrain_env_file" ]]; then
  while IFS= read -r _gbrain_env_line || [[ -n "$_gbrain_env_line" ]]; do
    case "$_gbrain_env_line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac

    _gbrain_env_key=${_gbrain_env_line%%=*}
    _gbrain_env_value=${_gbrain_env_line#*=}

    case "$_gbrain_env_key" in
      [A-Za-z_]*) ;;
      *) continue ;;
    esac

    case "$_gbrain_env_key" in
      *[!A-Za-z0-9_]*) continue ;;
    esac

    case "$_gbrain_env_key" in
      GBRAIN_DATABASE_URL|GBRAIN_DIRECT_DATABASE_URL|VOYAGE_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|GBRAIN_WORKER_CONCURRENCY)
        export "$_gbrain_env_key=$_gbrain_env_value"
        ;;
    esac
  done < "$_gbrain_env_file"
fi

unset _gbrain_env_file _gbrain_env_line _gbrain_env_key _gbrain_env_value
