// Extracted reference snippet (v0)
// Source: arquitectura/tipos.md:202
// Purpose: documentation-only; may not compile as-is.

/// Identificador único de un artefacto (UUID opaco para el cliente).
pub opaque type ArtifactId {
  ArtifactId(String)
}

pub fn artifact_id(s: String) -> ArtifactId { ArtifactId(s) }
pub fn artifact_id_to_string(id: ArtifactId) -> String { let ArtifactId(s) = id s }

/// Genera un nuevo ArtifactId único.
pub fn generate_artifact_id() -> ArtifactId {
  ArtifactId(uuid.v7_string())
}

/// Entrada en el registro de artefactos.
pub type ArtifactEntry {
  ArtifactEntry(
    /// Path validado dentro del workspace
    path: WorkspacePath,
    /// Tipo MIME del artefacto
    mime: String,
    /// Instancia que generó el artefacto (para cleanup)
    instance_id: InstanceId,
  )
}

/// Protocolo de mensajes del ArtifactRegistry.
/// El registry mapea ArtifactId → ArtifactEntry para servir /artifacts/:artifact_id.
pub type ArtifactRegistryMsg {
  /// Registra un nuevo artefacto. Devuelve el ArtifactId generado.
  RegisterArtifact(
    path: WorkspacePath,
    mime: String,
    instance_id: InstanceId,
    reply_to: Subject(ArtifactId),
  )
  
  /// Busca un artefacto por ID.
  LookupArtifact(
    artifact_id: ArtifactId,
    reply_to: Subject(Option(ArtifactEntry)),
  )
  
  /// Elimina todos los artefactos de una instancia.
  /// Se llama cuando se elimina la instancia (cleanup del workspace).
  PurgeByInstance(
    instance_id: InstanceId,
    reply_to: Subject(Int),  // Número de artefactos eliminados
  )
}
