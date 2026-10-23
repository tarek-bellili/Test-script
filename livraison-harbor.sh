
#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Livraison Lumia : images Docker + chart Helm
# ==================================================

read -rp "Archive de livraison (.tgz) : " LIVRABLE
read -rp "Fichier values environnement (.yaml) : " VALUES_FILE
read -rp "Registry Harbor (sans https://) : " REGISTRY
read -rp "Projet Harbor : " PROJECT

# Vérifications
for CMD in podman helm tar find gzip; do
    command -v "$CMD" >/dev/null || {
        echo "Commande manquante : $CMD"
        exit 1
    }
done

[[ -f "$LIVRABLE" ]] || {
    echo "Archive introuvable : $LIVRABLE"
    exit 1
}

[[ -f "$VALUES_FILE" ]] || {
    echo "Fichier values introuvable : $VALUES_FILE"
    exit 1
}

[[ -n "$REGISTRY" && -n "$PROJECT" ]] || {
    echo "Registry et projet obligatoires."
    exit 1
}

# Dossier temporaire
WORKDIR=$(mktemp -d)
trap 'rm -rf -- "$WORKDIR"' EXIT

echo "=== 1. Extraction du livrable ==="

mkdir -p "$WORKDIR/livraison"
tar -xzf "$LIVRABLE" -C "$WORKDIR/livraison"

# Recherche du chart Helm
CHART_ARCHIVE=$(find "$WORKDIR/livraison" \
    -type f -name 'lumia-api-*.tgz' -print -quit)

[[ -n "$CHART_ARCHIVE" ]] || {
    echo "Chart Helm introuvable."
    exit 1
}

echo "=== 2. Extraction du chart Helm ==="

mkdir -p "$WORKDIR/chart"
tar -xzf "$CHART_ARCHIVE" -C "$WORKDIR/chart"

CHART_PATH="$WORKDIR/chart/lumia-api"

[[ -f "$CHART_PATH/Chart.yaml" ]] || {
    echo "Chart.yaml introuvable."
    exit 1
}

# Lecture des versions du chart
CHART_VERSION=$(helm show chart "$CHART_PATH" |
    awk '/^version:/ {gsub(/"/, "", $2); print $2}')

APP_VERSION=$(helm show chart "$CHART_PATH" |
    awk '/^appVersion:/ {gsub(/"/, "", $2); print $2}')

[[ -n "$CHART_VERSION" && -n "$APP_VERSION" ]] || {
    echo "Impossible de lire version ou appVersion."
    exit 1
}

echo "Version chart : $CHART_VERSION"
echo "Version application : $APP_VERSION"

echo "=== 3. Publication des images Docker ==="

# Le chargement Podman se fait depuis chaque archive.
for IMAGE in auth catalog chat completion model utility; do

    IMAGE_ARCHIVE=$(find "$WORKDIR/livraison" \
        -type f -name "lumia-${IMAGE}.tgz" -print -quit)

    [[ -n "$IMAGE_ARCHIVE" ]] || {
        echo "Archive manquante : lumia-${IMAGE}.tgz"
        exit 1
    }

    DEST="${REGISTRY}/${PROJECT}/lumia-${IMAGE}:${APP_VERSION}"

    echo "--------------------------------------"
    echo "Image : lumia-${IMAGE}"
    echo "Destination : $DEST"

    # Chargement de l'image
    LOAD_OUTPUT=$(podman load -i "$IMAGE_ARCHIVE")
    echo "$LOAD_OUTPUT"

    # Récupération du nom de l'image chargée
    SOURCE_IMAGE=$(printf '%s\n' "$LOAD_OUTPUT" |
        sed -nE 's/^Loaded image(s)?:[[:space:]]*//p' |
        tail -n 1)

    [[ -n "$SOURCE_IMAGE" ]] || {
        echo "Impossible d'identifier l'image chargée."
        exit 1
    }

    # Nouveau tag et publication
    podman tag "$SOURCE_IMAGE" "$DEST"
    podman push --tls-verify=false "$DEST"

    echo "OK : lumia-${IMAGE}"
done

echo "=== 4. Ajout des valeurs environnement ==="

VALUES_NAME=$(basename "$VALUES_FILE")

cp "$VALUES_FILE" "$CHART_PATH/$VALUES_NAME"

echo "Fichier ajouté : $VALUES_NAME"

echo "=== 5. Vérification du chart ==="

helm lint "$CHART_PATH" -f "$CHART_PATH/$VALUES_NAME"

echo "=== 6. Repackaging du chart ==="

mkdir -p "$WORKDIR/packages"

helm package "$CHART_PATH" \
    --destination "$WORKDIR/packages"

CHART_PACKAGE="$WORKDIR/packages/lumia-api-${CHART_VERSION}.tgz"

[[ -f "$CHART_PACKAGE" ]] || {
    echo "Package Helm introuvable."
    exit 1
}

echo "=== 7. Publication du chart dans Harbor ==="

helm push "$CHART_PACKAGE" \
    "oci://${REGISTRY}/${PROJECT}" \
    --insecure-skip-tls-verify

echo
echo "======================================"
echo "LIVRAISON TERMINÉE"
echo "======================================"
echo "Registry          : $REGISTRY"
echo "Projet            : $PROJECT"
echo "Tag images        : $APP_VERSION"
echo "Version chart     : $CHART_VERSION"
echo "Fichier values    : $VALUES_NAME"
echo "======================================"
