#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_DIR="${SCRIPT_DIR}/.manager"
DEFAULTS_FILE="${MANAGER_DIR}/defaults.env"
DEFAULT_INSTANCES_DIR="${SCRIPT_DIR}/instances"

INSTANCE_NAME=""
DELETE_ALL=0
PURGE_DEFAULTS=0

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./uninstall-openclaw.sh --name <instance-name>
  ./uninstall-openclaw.sh --all
  ./uninstall-openclaw.sh

Options:
  --name <instance-name>  删除指定实例
  --all                   删除全部实例
  --purge-defaults        删除已保存的默认参数文件
  -h, --help              显示帮助
EOF
}

compose() {
  docker compose --env-file "$1" -f "$2" "${@:3}"
}

prompt_yes_no() {
  local label="$1"
  local default_answer="${2:-N}"
  local answer=""

  read -r -p "${label} [${default_answer}/$([[ "$default_answer" == "Y" ]] && printf 'n' || printf 'y')]: " answer
  answer="${answer:-$default_answer}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

choose_instance() {
  local instances_dir="$1"
  local items=()
  local item=""

  [[ -d "$instances_dir" ]] || fail "当前没有实例目录: ${instances_dir}"

  while IFS= read -r item; do
    items+=("$item")
  done < <(find "$instances_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  [[ "${#items[@]}" -gt 0 ]] || fail "当前没有可删除的实例"

  printf '可删除实例:\n'
  printf '  %s\n' "${items[@]}"
  read -r -p "请输入实例名: " INSTANCE_NAME
  [[ -n "$INSTANCE_NAME" ]] || fail "实例名不能为空"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || fail "--name 需要实例名"
        INSTANCE_NAME="$2"
        shift 2
        ;;
      --all)
        DELETE_ALL=1
        shift
        ;;
      --purge-defaults)
        PURGE_DEFAULTS=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

remove_stale_project_containers() {
  local project_name="$1"
  local container_ids=""

  container_ids="$(docker ps -aq --filter "name=^${project_name}-openclaw-")"
  if [[ -n "$container_ids" ]]; then
    docker rm -f $container_ids >/dev/null 2>&1 || true
  fi
}

remove_instance() {
  local instance_name="$1"
  local instance_dir="${INSTANCES_DIR}/${instance_name}"
  local env_file="${instance_dir}/.env"
  local compose_file="${instance_dir}/compose.yml"
  local project_name="$instance_name"

  if [[ ! -d "$instance_dir" ]]; then
    warn "实例目录不存在，跳过: ${instance_name}"
    remove_stale_project_containers "$project_name"
    docker network rm "${project_name}_default" >/dev/null 2>&1 || true
    return
  fi

  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
    project_name="${COMPOSE_PROJECT_NAME:-$instance_name}"
  fi

  info "删除实例: ${instance_name}"
  if [[ -f "$env_file" && -f "$compose_file" ]]; then
    compose "$env_file" "$compose_file" down --remove-orphans >/dev/null 2>&1 || true
  fi
  remove_stale_project_containers "$project_name"
  docker network rm "${project_name}_default" >/dev/null 2>&1 || true
  rm -rf "$instance_dir"
}

remove_all_instances() {
  local found=0
  local instance_path=""

  if [[ ! -d "$INSTANCES_DIR" ]]; then
    warn "实例目录不存在，无需删除: ${INSTANCES_DIR}"
    return
  fi

  while IFS= read -r instance_path; do
    found=1
    remove_instance "$(basename "$instance_path")"
  done < <(find "$INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  if [[ "$found" == "0" ]]; then
    warn "没有找到可删除的实例"
  fi

  rmdir "$INSTANCES_DIR" >/dev/null 2>&1 || true
}

main() {
  parse_args "$@"

  INSTANCES_DIR="$DEFAULT_INSTANCES_DIR"
  if [[ -f "$DEFAULTS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DEFAULTS_FILE"
    INSTANCES_DIR="${INSTANCES_DIR:-$DEFAULT_INSTANCES_DIR}"
  fi

  if [[ "$DELETE_ALL" == "1" && -n "$INSTANCE_NAME" ]]; then
    fail "--all 和 --name 不能同时使用"
  fi

  if [[ "$DELETE_ALL" == "1" ]]; then
    prompt_yes_no "确认删除全部实例及其实例目录" "N" || fail "已取消"
    remove_all_instances
  else
    if [[ -z "$INSTANCE_NAME" ]]; then
      choose_instance "$INSTANCES_DIR"
    fi
    prompt_yes_no "确认删除实例 ${INSTANCE_NAME} 及其目录" "N" || fail "已取消"
    remove_instance "$INSTANCE_NAME"
  fi

  if [[ "$PURGE_DEFAULTS" == "1" && -f "$DEFAULTS_FILE" ]]; then
    rm -f "$DEFAULTS_FILE"
    info "已删除默认参数文件: ${DEFAULTS_FILE}"
  fi

  info "删除完成"
}

main "$@"
