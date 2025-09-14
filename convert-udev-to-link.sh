#!/usr/bin/env bash
set -euo pipefail

UDEV_RULE="/etc/udev/rules.d/70-persistent-net.rules"
LINK_DIR="/etc/systemd/network"
timestamp="$(date +%F-%H%M%S)"

if [[ ! -f "$UDEV_RULE" ]]; then
  echo "Ошибка: $UDEV_RULE не найден." >&2
  exit 1
fi

# Бэкап udev-файла
sudo cp "$UDEV_RULE" "${UDEV_RULE}.bak-${timestamp}"
echo "Сделан бэкап: ${UDEV_RULE}.bak-${timestamp}"

# Создать директорию для .link файлов, если нужно
sudo mkdir -p "$LINK_DIR"

# Функция проверки MAC
is_valid_mac() {
  local m="$1"
  [[ "$m" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

# Пройти по каждой строке и извлечь пары ATTR{address} и NAME
# Поддерживаются записи с = и == (например ATTR{address}==".." или ATTR{address}="..")
processed=0
while IFS= read -r line; do
  # Пропустить пустые строки и комментарии
  [[ -z "${line//[[:space:]]/}" ]] && continue
  [[ "${line#"${line%%[![:space:]]*}"}" == "#" ]] && continue
  # Попытка извлечь MAC и NAME с помощью awk (регулярки поддерживают = или ==)
  mac=$(awk 'match($0, /ATTR\{address\}={1,2}"([^"]+)"/, m){print m[1]}' <<<"$line" || true)
  name=$(awk 'match($0, /NAME={1,2}"([^"]+)"/, m){print m[1]}' <<<"$line" || true)

  # Если не нашли в одной и той же строке — пробуем найти NAME и MAC отдельно, но только в пределах одной записи.
  # Допустим, запись может быть в нескольких частях — тогда попробуем извлечь из всей строки уже найденные значения.
  if [[ -z "$mac" && -n "$line" ]]; then
    mac=$(awk 'match($0, /ATTR\{address\}={1,2}"([^"]+)"/, m){print m[1]}' <<<"$line" || true)
  fi
  if [[ -z "$name" && -n "$line" ]]; then
    name=$(awk 'match($0, /NAME={1,2}"([^"]+)"/, m){print m[1]}' <<<"$line" || true)
  fi

  # Если обе величины найдены — обрабатывать
  if [[ -n "$mac" && -n "$name" ]]; then
    if ! is_valid_mac "$mac"; then
      echo "Предупреждение: пропускаю запись с некорректным MAC: $mac" >&2
      continue
    fi

    # Сформировать имя .link файла (избегаем пробелов)
    safe_name="$(echo "$name" | tr -c 'A-Za-z0-9_-' '_' )"
    link_file="${LINK_DIR}/10-${safe_name}.link"

    sudo tee "$link_file" > /dev/null <<EOF
[Match]
MACAddress=${mac}

[Link]
Name=${name}
EOF

    echo ".link создан: $link_file (MAC: $mac -> Name: $name)"
    processed=$((processed + 1))
  fi
done < "$UDEV_RULE"

if [[ $processed -eq 0 ]]; then
  echo "Ни одной пары MAC/NAME не найдено в $UDEV_RULE." >&2
  echo "Файл оставлен без изменений." >&2
  exit 2
fi

# Удаляем старый udev-файл (по заданию)
sudo rm -f "$UDEV_RULE"
echo "Удалён старый udev-файл: $UDEV_RULE"

# Перезапустить systemd-udevd чтобы применить изменения
sudo systemctl restart systemd-udevd
echo "systemd-udevd перезапущен. Обработано записей: $processed"
