// Extracted reference snippet (v0)
// Source: arquitectura/actores.md
// Purpose: documentation-only; may not compile as-is.

// Ubicación: sad/core/messages.gleam

/// Protocolo del SSOT de perfiles en memoria (ProfilesActor).
pub type ProfilesMsg {
  /// Reemplaza el conjunto completo de perfiles (operación pura, sin IO).
  /// Devuelve el número de perfiles establecidos.
  SetProfiles(Dict(ProfileId, Profile), Subject(Int))
  /// Obtiene un perfil por id.
  GetProfile(ProfileId, Subject(Option(Profile)))
  /// Lista ids disponibles.
  ListProfiles(Subject(List(ProfileId)))
}

