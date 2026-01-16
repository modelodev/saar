# Modelo de seguridad (v0)

Plan version: v2.1

## Objetivo
- Reducir el impacto de runners maliciosos o defectuosos sin romper compatibilidad.
- Mantener un modelo simple y auditable para v0: Landlock + namespaces best-effort.
- Evitar dependencias de kernel no disponibles en CI o contenedores.

## No-goals v0
- No hay sandbox de red (no se bloquea salida de red).
- No hay aislamiento por mount namespace ni seccomp.
- No hay allowlist dinámica por perfil o por capability (solo defaults globales).

## Componentes de seguridad v0
1) **PID namespace** (best-effort)
   - Se intenta crear PID+user namespace.
   - Si falla, se usa fallback de process group.

2) **Landlock** (filesystem policy)
   - Se aplica en el wrapper al proceso runner.
   - Controla permisos de lectura/escritura/ejecucion por path.
   - No modifica mounts; solo aplica restricciones.

Nota: estas restricciones aplican al **runner**, no al proceso SAAR. El servicio SAAR
puede necesitar paths de sistema para config y logs (p.ej. `/etc/saar/config.toml`,
`/var/log/saar`), pero eso no forma parte del sandbox del runner.

## Landlock modes
Config key: `security.landlock_mode`
- `off`: no intenta Landlock.
- `best_effort` (default): intenta; si falla, continua sin Landlock.
- `enforced`: intenta; si falla, la instancia/interaccion falla con:
  - `failure_reason="LANDLOCK_UNAVAILABLE"`

Notas:
- En `best_effort`, si `DEBUG=1`, el wrapper escribe diagnostico en STDERR.
- En `enforced`, el fallo es por instancia, no tumba el servicio completo.

## Allowlist global (v0)
Las rutas se permiten por tipo de permiso. Fuera de esta lista: denegado.

### Read-only (R)
- `/etc`
- `/run/systemd/resolve/`
- `/proc/self`
- `/dev/random`
- `/dev/urandom`

### Read + Exec (R+X)
- `/bin`
- `/lib`
- `/lib64`
- `/usr`
- `/home` (required for local profile sources)

### Read + Write + Exec (R+W+X)
- `<workspace_dir>` de la instancia
- `/tmp`
- `/var/tmp`
- `/dev/null`

## Paths derivados del source
Cuando el runner proviene de `profiles.sources`:
- `<source_root>/runners` (R+X)
- `<source_root>/profiles` (R)

Nota: en v0 el wrapper deriva `<source_root>` desde el directorio actual del runner
(`SAAR_WORKSPACE` / `workspaces.directory`). Eso cubre `profiles.sources = dir`.

## Efectos esperados
- El runner puede leer certificados y resolucion DNS del sistema.
- El runner puede ejecutar binarios del sistema y del source.
- El runner solo puede escribir en el workspace y en `/tmp`/`/var/tmp`.
- No se puede leer `/proc` global ni `/sys`.

## Errores y fallback
- `best_effort`: si Landlock no esta soportado, se ejecuta sin restriccion y se continua.
- `enforced`: si Landlock falla, la interaccion/provisioning falla y el agente transita a `Failed`.

## Compatibilidad y riesgos
- Algunos runners pueden requerir mas paths (p.ej. certificados en ubicaciones no estandar).
  Esto se resuelve post-v0 con allowlists configurables por driver o por perfil.
- Permitir `/tmp` y `/var/tmp` mejora compatibilidad, pero reduce aislamiento entre instancias.

## Allowlists post-v0 (candidatos)
Estos paths no estan permitidos por defecto en v0, pero son candidatos comunes
si un driver lo requiere y se decide abrir el scope:
- `$HOME/.cache` (modelos descargados, caches de HTTP)
- `$HOME/.config` (config local del runner)
- `$HOME/.local/share` (data local de herramientas)
- `$HOME/.local/bin` (binarios de usuario)
- `$HOME/.gitconfig` (si el runner invoca git con config de usuario)
