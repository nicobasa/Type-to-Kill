# Roblox Model Naming Style

## Core Principles

### Use PascalCase for All Instances
All Roblox instances (objects) MUST use **PascalCase** naming convention.

```lua
-- CORRECT
Workspace.PlayerSpawnPoint
ReplicatedStorage.WeaponModels
ServerStorage.NPCTemplates

-- INCORRECT
workspace.player_spawn_point
ReplicatedStorage.weapon-models
ServerStorage.npc_templates
```

## Naming Rules by Category

### Models
```lua
-- Singular, descriptive names
CarModel
TreeModel
HouseModel
PlayerCharacter
PowerUp

-- Plural for containers
WeaponModels (folder containing multiple weapon models)
NPCModels
EffectModels
```

### Parts
```lua
-- Clear role description
Floor
Wall
Ceiling
Hitbox
SpawnPoint

-- Add number or position for multiples
Wall1, Wall2, Wall3
LeftDoor, RightDoor
FrontWheel, BackWheel
```

### Attachments
```lua
-- Always suffix with "Attachment"
GripAttachment
MuzzleAttachment
HandleAttachment
BarrelAttachment
```

### Folders
```lua
-- Plural to indicate grouping
Weapons
Effects
Tools
NPCs
Buildings

-- Or clear purpose
PlayerData
GameSettings
MapObjects
ArenaElements
```

### MeshParts & Unions
```lua
-- Specific descriptions
CarBody
WheelMesh
GunBarrel
TreeTrunk
```

## Hierarchy Structure Example

```
Workspace
├── Map
│   ├── Buildings
│   │   ├── House1
│   │   ├── House2
│   │   └── Shop
│   ├── Terrain
│   │   ├── Ground
│   │   └── WaterArea
│   └── SpawnPoints
│       ├── PlayerSpawn1
│       └── PlayerSpawn2
├── Effects
│   ├── ExplosionEffect
│   └── SparkEffect
└── NPCs
    ├── ZombieModel
    └── GuardModel
```

## Anti-Patterns (DO NOT USE)

```lua
-- ❌ Too vague
Part
Model
Thing
Object

-- ❌ Inconsistent casing
player_spawn  -- snake_case
PlayerModel   -- PascalCase
weaponmodel   -- lowercase

-- ❌ Special characters
Player@Spawn
Weapon#1
Model-2023

-- ❌ Default names left unchanged
"Part" (default name)
"Model" (default name)
"   " (empty/whitespace)
```

## Project-Specific Conventions

The rules above are universal. Anything specific to *this* project — its gameplay nouns, its instance tree, its service layout — is not listed here on purpose.

**Derive it, don't assume it.** Before naming or renaming anything:

1. Read `ARCHITECTURE.md` / `CLAUDE.md` if present — the tree and its conventions are usually documented there.
2. Read `default.project.json` — it is the authoritative map from disk to the Roblox tree. Never assume a service layout; a project may mount `Services` under `ServerStorage` rather than `ServerScriptService`, or use any other arrangement.
3. Look at the existing siblings. Two files agreeing is a convention; one is not.

If you add project-specific conventions to this file, date them and keep them true — a stale convention block is worse than none, because it is followed confidently.

## Checklist Before Creating/Renaming Models

- [ ] Uses PascalCase
- [ ] Name is descriptive and specific
- [ ] Consistent with existing naming patterns
- [ ] Not using default names (Part, Model, etc.)
- [ ] No special characters or spaces in inappropriate places
- [ ] Hierarchy is logical and organized

## Team Standards

1. **PascalCase** for all instances
2. **Descriptive** names that explain purpose
3. **Consistency** across the project
4. **Hierarchy** structure for grouping
5. Never leave default names unchanged
6. **Document** any project-specific conventions

These naming conventions improve code readability, maintainability, and team collaboration.
