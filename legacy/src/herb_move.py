"""
HERB v2: The MOVE Primitive

THE OPERATION SET IS THE CONSTRAINT SYSTEM.

Invalid states aren't checked and rejected. They're unreachable because
no sequence of valid operations leads to them.

MOVE is the fundamental primitive covering:
- Containment (entity in scope)
- Conservation (quantity between holders)
- State machines (entity in state-as-container)

See MOVE_PRIMITIVE.md for the full design.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Dict, List, Set, Optional, Any, Tuple as PyTuple, Callable
import time


# =============================================================================
# OPERATION LOG (Provenance)
# =============================================================================

@dataclass
class Operation:
    """
    A record of an operation that occurred.
    Operations are primitive; state is derived by replaying operations.
    """
    id: int
    op_type: str                      # The operation type name
    params: Dict[str, Any]            # Parameters to the operation
    timestamp: int                    # When this occurred (tick)
    micro: int                        # Sub-tick ordering
    cause: str                        # Why this happened ('external', 'derived', etc.)
    source_ops: List[int] = field(default_factory=list)  # Operations that triggered this


# =============================================================================
# TENSIONS (Energy Gradients)
# =============================================================================

@dataclass
class IntendedMove:
    """
    A move that a tension wants to execute.

    This is not an operation — it's a DESIRE. The runtime attempts it.
    If the operation doesn't exist (slot full, wrong container, etc.),
    it simply doesn't happen. Safety is preserved.
    """
    move_name: str
    entity_id: int
    to_container: int


@dataclass
class IntendedTransfer:
    """
    A quantity transfer that a tension wants to execute.

    Transfers quantity from one entity to another within a conservation pool.
    If the source doesn't have enough, the operation doesn't exist.
    Conservation is structural: total in pool never changes.
    """
    transfer_name: str
    from_entity: int
    to_entity: int
    amount: Any  # Resolved to a number at runtime


@dataclass
class IntendedCreate:
    """
    An entity creation that a tension wants to execute.

    Creates a new entity and places it in a container.
    Only valid entity types and containers can be used.
    """
    entity_type: int
    container: int
    properties: Dict[str, Any] = field(default_factory=dict)
    name: Optional[str] = None


@dataclass
class IntendedSet:
    """
    A property mutation that a tension wants to execute.

    Sets a non-conserved property on an entity. Conserved properties
    (those tracked by a conservation pool) can only change via transfer.
    This is for counters, timers, flags, scores — values that don't
    require a conservation partner.
    """
    entity_id: int
    property_name: str
    value: Any


@dataclass
class IntendedSend:
    """
    A channel send that a tension wants to execute.

    Moves an entity from the sender's scope into the channel buffer.
    The entity must be in a container owned by the channel's designated
    sender. After send, the sender loses access — the entity is in the
    channel, not in any process's scope. This is Zircon's model:
    channel write atomically removes the handle from the sender.
    """
    channel_name: str
    entity_id: int


@dataclass
class IntendedReceive:
    """
    A channel receive that a tension wants to execute.

    Moves an entity from the channel buffer into the receiver's scope.
    The target container must be owned by the channel's designated
    receiver. After receive, the entity is in the receiver's scope.
    """
    channel_name: str
    entity_id: int
    to_container: int


@dataclass
class IntendedDuplicate:
    """
    An entity duplication that a tension wants to execute.

    Creates an exact copy of an entity (same type, same properties)
    and places it in the specified container. The original is unchanged.
    This is Zircon's handle_duplicate: you must explicitly copy before
    sending if you want to retain access. No implicit sharing.
    """
    source_entity: int
    container: int
    name: Optional[str] = None


@dataclass
class Tension:
    """
    A tension declares: when this condition holds, this MOVE should execute.
    
    Tensions are the energy gradients of the system. They create "pressure"
    for state changes. The runtime resolves tensions to fixpoint (equilibrium).
    
    A tension's check function examines the current graph state and returns
    a list of IntendedMoves. An empty list means the tension is satisfied
    (no gradient — at equilibrium for this tension).
    
    CRITICAL: Tensions can only trigger MOVEs in the operation set.
    A tension that wants an invalid state change simply fails — the MOVE
    doesn't exist. Safety guarantees from Discovery 1 are preserved.
    """
    name: str
    check: Callable[['MoveGraph'], List[IntendedMove]]
    priority: int = 0  # Higher priority tensions resolve first


# =============================================================================
# CONTAINERS
# =============================================================================

class ContainerKind(Enum):
    """Types of containers."""
    SIMPLE = auto()       # Just holds entities, no limit
    SLOT = auto()         # Holds exactly one entity (or empty)
    POOL = auto()         # Holds a quantity, tracks conservation


@dataclass
class Container:
    """
    A container holds entities or quantities.

    For state machines, states ARE containers. A process being in the
    READY state means the process entity is IN the READY_QUEUE container.

    Containers can belong to a DIMENSION. Dimensions are independent
    state spaces — an entity occupies one container per dimension.
    Containers without a dimension are in the default (unnamed) dimension.
    """
    id: int
    name: str
    kind: ContainerKind
    entity_type: Optional[int] = None  # What type of entity can be in this container

    # For POOL kind: conservation tracking
    pool_id: Optional[int] = None      # Which conservation pool this belongs to

    # Dimension: None = default dimension, str = named dimension
    dimension: Optional[str] = None

    # Current contents (derived from operations, but cached for performance)
    _entities: Set[int] = field(default_factory=set)
    _quantity: int = 0

    def contains(self, entity_id: int) -> bool:
        """Check if an entity is in this container."""
        return entity_id in self._entities

    def is_empty(self) -> bool:
        """Check if container is empty."""
        return len(self._entities) == 0

    @property
    def count(self) -> int:
        """Number of entities in this container."""
        return len(self._entities)


# =============================================================================
# MOVE TYPES
# =============================================================================

@dataclass
class MoveType:
    """
    A type of move operation.

    This declares WHICH moves are valid. If a (from, to) pair isn't
    declared in any MoveType, that move doesn't exist.

    Regular moves: from_containers and to_containers are fixed container IDs.
    Scoped moves: scoped_from and scoped_to are container NAMES within an
    entity's scoped namespace. The operation only exists within a single
    entity's scope — cross-scope moves are structurally impossible.
    """
    name: str
    from_containers: List[int]        # Container IDs this move can originate from
    to_containers: List[int]          # Container IDs this move can go to
    entity_type: Optional[int] = None # What type of entity can be moved

    # For quantity moves
    is_quantity_move: bool = False

    # Additional checks (beyond from/to validity)
    # These are NOT constraint checks — they determine if the operation EXISTS
    # Signature: (graph, entity_id, from_container, to_container, params) -> bool
    existence_check: Any = None

    # Scoped move support
    is_scoped: bool = False
    scoped_from: List[str] = field(default_factory=list)  # Scope container names
    scoped_to: List[str] = field(default_factory=list)    # Scope container names


# =============================================================================
# ENTITIES
# =============================================================================

@dataclass
class Entity:
    """
    An entity in the graph.
    """
    id: int
    type_id: int
    name: Optional[str] = None
    created_at: int = 0
    properties: Dict[str, Any] = field(default_factory=dict)


# =============================================================================
# THE GRAPH
# =============================================================================

class MoveGraph:
    """
    The graph based on MOVE as the fundamental primitive.

    Operations are primitive. State is derived.
    Invalid states are unreachable by construction.
    """

    def __init__(self):
        # Entities
        self.entities: Dict[int, Entity] = {}
        self.next_entity_id: int = 1

        # Entity types (also entities)
        self.entity_types: Dict[int, str] = {}  # type_id -> type_name

        # Containers
        self.containers: Dict[int, Container] = {}
        self.container_by_name: Dict[str, int] = {}
        self.next_container_id: int = 1

        # Conservation pools
        self.pools: Dict[int, int] = {}  # pool_id -> total quantity
        self.next_pool_id: int = 1

        # Move types (the operation set)
        self.move_types: Dict[str, MoveType] = {}

        # Entity location index: entity_id -> container_id
        # Each entity is in exactly one container (or none if not placed)
        self.entity_location: Dict[int, int] = {}

        # Operation log
        self.operations: List[Operation] = []
        self.next_op_id: int = 1
        self.current_tick: int = 0
        self.current_micro: int = 0

        # Name indices
        self.entity_by_name: Dict[str, int] = {}

        # Tensions (energy gradients)
        self.tensions: Dict[str, Tension] = {}  # name -> Tension

        # Conservation pools: pool_name -> {"property": str}
        self.pool_defs: Dict[str, dict] = {}

        # Transfer types: transfer_name -> {"pool": str, "entity_type": Optional[int]}
        self.transfer_types: Dict[str, dict] = {}

        # Auto-incrementing name counter for dynamic entity creation
        self._auto_name_counter: int = 0

        # Scoped containers: per-entity isolated namespaces
        # Type-level: which types have scoped container templates
        self.entity_type_scopes: Dict[int, List[dict]] = {}
        # Instance-level: which containers belong to which entity
        self.container_owner: Dict[int, int] = {}  # container_id -> owner entity_id
        self.entity_scoped_containers: Dict[int, Dict[str, int]] = {}  # entity_id -> {scope_name: container_id}

        # Channels: typed cross-scope communication
        self.channels: Dict[str, dict] = {}  # channel_name -> channel def

        # Nesting depth bound (None = unlimited)
        self.max_nesting_depth: Optional[int] = None

        # Dimensions: independent state spaces for entities
        # container_dimension: container_id -> dimension name (None = default)
        self.container_dimension: Dict[int, Optional[str]] = {}
        # entity_dim_locations: entity_id -> {dimension_name: container_id}
        # Only tracks NAMED dimensions. Default dimension uses entity_location.
        self.entity_dim_locations: Dict[int, Dict[str, int]] = {}

    # =========================================================================
    # CHANNELS (Inter-Scope Communication)
    # =========================================================================

    def define_channel(
        self,
        name: str,
        sender_id: int,
        receiver_id: int,
        entity_type: Optional[int] = None
    ) -> int:
        """
        Define a typed channel between two entities.

        A channel is the ONLY way to cross scope boundaries. It creates
        a buffer container where entities transit between scopes. The
        sender can put entities in; the receiver can take them out.
        No other cross-scope operation exists.

        This follows Zircon's model: handles are moved through channels.
        The sender loses access on send. The receiver gains access on
        receive. The channel is the mediator.

        Returns the buffer container ID.
        """
        # Create the channel buffer container
        buffer_cid = self.define_container(
            f"channel:{name}",
            ContainerKind.SIMPLE,
            entity_type
        )

        self.channels[name] = {
            "name": name,
            "sender_id": sender_id,
            "receiver_id": receiver_id,
            "entity_type": entity_type,
            "buffer_container": buffer_cid,
        }

        return buffer_cid

    def channel_send(
        self,
        channel_name: str,
        entity_id: int,
        cause: str = 'external',
        source_ops: Optional[List[int]] = None
    ) -> Optional[int]:
        """
        Send an entity through a channel.

        The entity must be in a container owned by the channel's sender.
        After send, the entity is in the channel buffer — the sender
        has lost access. This is a MOVE, not a copy.

        Returns operation ID, or None if the operation doesn't exist.
        """
        channel = self.channels.get(channel_name)
        if channel is None:
            return None

        entity = self.entities.get(entity_id)
        if entity is None:
            return None

        # Check entity type restriction
        if channel["entity_type"] is not None:
            if entity.type_id != channel["entity_type"]:
                return None

        # Entity must be in a container owned by the sender
        current = self.entity_location.get(entity_id)
        if current is None:
            return None

        owner = self.container_owner.get(current)
        if owner != channel["sender_id"]:
            return None  # Not in sender's scope — operation doesn't exist

        buffer_cid = channel["buffer_container"]

        # Atomic move: sender's scope → channel buffer
        self.containers[current]._entities.remove(entity_id)
        self.containers[buffer_cid]._entities.add(entity_id)
        self.entity_location[entity_id] = buffer_cid

        # Log the operation
        op = Operation(
            id=self.next_op_id,
            op_type='channel_send',
            params={
                'entity_id': entity_id,
                'channel': channel_name,
                'from_container': current,
                'to_container': buffer_cid,
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=cause,
            source_ops=source_ops or []
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    def channel_receive(
        self,
        channel_name: str,
        entity_id: int,
        to_container: int,
        cause: str = 'external',
        source_ops: Optional[List[int]] = None
    ) -> Optional[int]:
        """
        Receive an entity from a channel into the receiver's scope.

        The entity must be in the channel buffer. The target container
        must be owned by the channel's designated receiver.

        Returns operation ID, or None if the operation doesn't exist.
        """
        channel = self.channels.get(channel_name)
        if channel is None:
            return None

        entity = self.entities.get(entity_id)
        if entity is None:
            return None

        # Entity must be in the channel buffer
        current = self.entity_location.get(entity_id)
        if current != channel["buffer_container"]:
            return None  # Not in channel — operation doesn't exist

        # Target must be owned by the receiver
        target_owner = self.container_owner.get(to_container)
        if target_owner != channel["receiver_id"]:
            return None  # Not receiver's scope — operation doesn't exist

        # Check slot constraint
        target = self.containers.get(to_container)
        if target is None:
            return None
        if target.kind == ContainerKind.SLOT and not target.is_empty():
            return None

        # Check entity type on target container
        if target.entity_type is not None:
            if entity.type_id != target.entity_type:
                return None

        # Atomic move: channel buffer → receiver's scope
        self.containers[current]._entities.remove(entity_id)
        self.containers[to_container]._entities.add(entity_id)
        self.entity_location[entity_id] = to_container

        # Log the operation
        op = Operation(
            id=self.next_op_id,
            op_type='channel_receive',
            params={
                'entity_id': entity_id,
                'channel': channel_name,
                'from_container': current,
                'to_container': to_container,
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=cause,
            source_ops=source_ops or []
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    def duplicate_entity(
        self,
        source_entity_id: int,
        container: int,
        name: Optional[str] = None,
        cause: str = 'external',
        source_ops: Optional[List[int]] = None
    ) -> Optional[int]:
        """
        Create an exact copy of an entity.

        This is Zircon's handle_duplicate: you must explicitly copy
        before sending if you want to retain access. No implicit sharing.

        The copy has the same type and properties as the source.
        The source entity is unchanged.

        Returns the new entity's ID, or None if source doesn't exist.
        """
        source = self.entities.get(source_entity_id)
        if source is None:
            return None

        # Auto-generate name
        self._auto_name_counter += 1
        dup_name = name or f"_dup_{self._auto_name_counter}"

        new_id = self.create_entity(
            source.type_id,
            dup_name,
            container,
            dict(source.properties)
        )

        # Log the operation
        op = Operation(
            id=self.next_op_id,
            op_type='duplicate',
            params={
                'source_entity': source_entity_id,
                'new_entity': new_id,
                'container': container,
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=cause,
            source_ops=source_ops or []
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return new_id

    # =========================================================================
    # NESTING DEPTH
    # =========================================================================

    def get_nesting_depth(self, container_id: int) -> int:
        """
        Get the nesting depth of a container.

        Global containers = depth 0.
        Scoped containers owned by an entity in a depth-0 container = depth 1.
        And so on.
        """
        owner = self.container_owner.get(container_id)
        if owner is None:
            return 0  # Global container

        # Find which container the owner entity is in
        owner_location = self.entity_location.get(owner)
        if owner_location is None:
            return 1  # Owner not placed — assume depth 1

        return 1 + self.get_nesting_depth(owner_location)

    # =========================================================================
    # ENTITY TYPES
    # =========================================================================

    def define_entity_type(self, name: str) -> int:
        """Define a new entity type."""
        type_id = self.next_entity_id
        self.next_entity_id += 1

        self.entity_types[type_id] = name
        self.entity_by_name[name] = type_id

        return type_id

    def define_entity_type_scopes(self, type_id: int, scope_defs: List[dict]):
        """
        Define scoped container templates for an entity type.

        When entities of this type are created, each gets its own
        isolated instances of these containers. This is how HERB
        achieves per-entity namespaces: Process A's FD_TABLE and
        Process B's FD_TABLE are different containers. The operation
        to cross them doesn't exist.

        Each scope_def: {"name": str, "kind": ContainerKind, "entity_type": Optional[int]}
        """
        self.entity_type_scopes[type_id] = scope_defs

    def get_scoped_container(self, entity_id: int, scope_name: str) -> Optional[int]:
        """Get a scoped container ID for an entity by scope name."""
        scoped = self.entity_scoped_containers.get(entity_id)
        if scoped is None:
            return None
        return scoped.get(scope_name)

    # =========================================================================
    # CONTAINERS
    # =========================================================================

    def define_container(
        self,
        name: str,
        kind: ContainerKind = ContainerKind.SIMPLE,
        entity_type: Optional[int] = None,
        pool_id: Optional[int] = None,
        dimension: Optional[str] = None
    ) -> int:
        """
        Define a new container.

        For state machines, define one container per state.
        For conservation, containers in the same pool share a quantity total.
        If dimension is specified, the container belongs to that named
        dimension. Entities can occupy one container per dimension independently.
        """
        container_id = self.next_container_id
        self.next_container_id += 1

        container = Container(
            id=container_id,
            name=name,
            kind=kind,
            entity_type=entity_type,
            pool_id=pool_id,
            dimension=dimension
        )

        self.containers[container_id] = container
        self.container_by_name[name] = container_id
        self.container_dimension[container_id] = dimension

        return container_id

    def define_pool(self, name: str, total: int) -> int:
        """
        Define a conservation pool.

        All containers in this pool share a total quantity.
        """
        pool_id = self.next_pool_id
        self.next_pool_id += 1

        self.pools[pool_id] = total
        self.entity_by_name[f"pool:{name}"] = pool_id

        return pool_id

    # =========================================================================
    # MOVE TYPES (THE OPERATION SET)
    # =========================================================================

    def define_move(
        self,
        name: str,
        from_containers: List[int] = None,
        to_containers: List[int] = None,
        entity_type: Optional[int] = None,
        is_quantity_move: bool = False,
        existence_check: Any = None,
        is_scoped: bool = False,
        scoped_from: Optional[List[str]] = None,
        scoped_to: Optional[List[str]] = None,
    ):
        """
        Define a type of move operation.

        Regular moves: from/to are fixed container ID lists.
        Scoped moves: scoped_from/scoped_to are container NAMES within
        an entity's scope. The runtime ensures source and target belong
        to the same owning entity — cross-scope operations don't exist.
        """
        move_type = MoveType(
            name=name,
            from_containers=from_containers or [],
            to_containers=to_containers or [],
            entity_type=entity_type,
            is_quantity_move=is_quantity_move,
            existence_check=existence_check,
            is_scoped=is_scoped,
            scoped_from=scoped_from or [],
            scoped_to=scoped_to or [],
        )

        self.move_types[name] = move_type

    # =========================================================================
    # ENTITY OPERATIONS
    # =========================================================================

    def create_entity(
        self,
        type_id: int,
        name: Optional[str] = None,
        initial_container: Optional[int] = None,
        properties: Optional[Dict[str, Any]] = None
    ) -> int:
        """
        Create a new entity.

        If initial_container is specified, place the entity there.
        If properties is specified, set initial property values.
        If the entity type has scoped container definitions, auto-create
        isolated container instances for this entity.
        """
        entity_id = self.next_entity_id
        self.next_entity_id += 1

        entity = Entity(
            id=entity_id,
            type_id=type_id,
            name=name,
            created_at=self.current_tick,
            properties=dict(properties) if properties else {}
        )

        self.entities[entity_id] = entity

        if name:
            self.entity_by_name[name] = entity_id

        if initial_container is not None:
            # Direct placement (for initialization)
            container = self.containers.get(initial_container)
            if container:
                container._entities.add(entity_id)
                self.entity_location[entity_id] = initial_container

        # Auto-create scoped containers for types that define them
        # Check nesting depth bound first
        if type_id in self.entity_type_scopes and self.max_nesting_depth is not None:
            if initial_container is not None:
                depth = self.get_nesting_depth(initial_container) + 1
                if depth > self.max_nesting_depth:
                    # Nesting too deep — operation doesn't exist
                    # Entity was created but without scoped containers
                    return entity_id

        if type_id in self.entity_type_scopes:
            scoped = {}
            ent_name = name or f"_e{entity_id}"
            for scope_def in self.entity_type_scopes[type_id]:
                scope_name = scope_def["name"]
                kind = scope_def.get("kind", ContainerKind.SIMPLE)
                et_id = scope_def.get("entity_type")
                cname = f"{ent_name}::{scope_name}"
                cid = self.define_container(cname, kind, et_id)
                self.container_owner[cid] = entity_id
                scoped[scope_name] = cid
            self.entity_scoped_containers[entity_id] = scoped

        return entity_id

    # =========================================================================
    # MOVE OPERATIONS
    # =========================================================================

    def _get_move_dimension(self, move_type: MoveType) -> Optional[str]:
        """
        Determine which dimension a move operates in.

        A move's dimension is the dimension of its containers. All containers
        in a move must be in the same dimension. Returns None for default
        dimension, the dimension name for named dimensions.
        """
        if move_type.is_scoped:
            return None  # Scoped moves are always default dimension

        # Check from_containers and to_containers for dimension
        all_container_ids = move_type.from_containers + move_type.to_containers
        if not all_container_ids:
            return None

        dims = set()
        for cid in all_container_ids:
            dim = self.container_dimension.get(cid)
            dims.add(dim)

        # All containers should be in the same dimension
        if len(dims) == 1:
            return dims.pop()
        # Mixed dimensions — shouldn't happen with well-formed programs
        return None

    def _get_entity_position_in_dimension(
        self,
        entity_id: int,
        dimension: Optional[str]
    ) -> Optional[int]:
        """
        Get entity's container in a specific dimension.

        Returns container_id or None if entity isn't positioned in that dimension.
        """
        if dimension is None:
            return self.entity_location.get(entity_id)
        else:
            dim_locs = self.entity_dim_locations.get(entity_id, {})
            return dim_locs.get(dimension)

    def operation_exists(
        self,
        move_name: str,
        entity_id: int,
        to_container: int,
        **params
    ) -> PyTuple[bool, Optional[str]]:
        """
        Check if a move operation EXISTS (not if it's "allowed" — there's no
        "allowed", only "exists" or "doesn't exist").

        Returns (exists, reason_if_not).
        """
        move_type = self.move_types.get(move_name)
        if move_type is None:
            return False, f"Move type '{move_name}' not defined"

        entity = self.entities.get(entity_id)
        if entity is None:
            return False, f"Entity {entity_id} does not exist"

        # Check entity type matches
        if move_type.entity_type is not None:
            if entity.type_id != move_type.entity_type:
                return False, f"Entity type {entity.type_id} != required {move_type.entity_type}"

        # Determine the move's dimension and get entity position in it
        move_dim = self._get_move_dimension(move_type)
        current_container = self._get_entity_position_in_dimension(entity_id, move_dim)

        if current_container is None:
            if move_dim is None:
                return False, f"Entity {entity_id} is not in any container"
            else:
                return False, f"Entity {entity_id} not in dimension '{move_dim}'"

        if move_type.is_scoped:
            # === SCOPED MOVE: source and target must belong to same entity ===
            source_owner = self.container_owner.get(current_container)
            if source_owner is None:
                return False, f"Entity not in a scoped container"

            source_scopes = self.entity_scoped_containers.get(source_owner, {})
            source_scope = None
            for sn, cid in source_scopes.items():
                if cid == current_container:
                    source_scope = sn
                    break
            if source_scope not in move_type.scoped_from:
                return False, f"Source scope '{source_scope}' not in {move_type.scoped_from}"

            target_owner = self.container_owner.get(to_container)
            if target_owner != source_owner:
                return False, f"Cross-scope move: isolation violation"

            target_scope = None
            for sn, cid in source_scopes.items():
                if cid == to_container:
                    target_scope = sn
                    break
            if target_scope not in move_type.scoped_to:
                return False, f"Target scope '{target_scope}' not in {move_type.scoped_to}"
        else:
            # === REGULAR MOVE ===
            # Check from_container is in allowed list
            if current_container not in move_type.from_containers:
                from_name = self.containers[current_container].name
                allowed = [self.containers[c].name for c in move_type.from_containers]
                return False, f"Entity in '{from_name}', not in allowed from: {allowed}"

            # Check to_container is in allowed list
            if to_container not in move_type.to_containers:
                to_name = self.containers[to_container].name
                allowed = [self.containers[c].name for c in move_type.to_containers]
                return False, f"Target '{to_name}' not in allowed to: {allowed}"

        # Common checks for both scoped and regular moves
        target = self.containers.get(to_container)
        if target is None:
            return False, f"Target container {to_container} does not exist"

        if target.entity_type is not None:
            if entity.type_id != target.entity_type:
                return False, f"Container '{target.name}' only accepts type {target.entity_type}"

        # Check slot constraint
        if target.kind == ContainerKind.SLOT and not target.is_empty():
            return False, f"Slot '{target.name}' is already occupied"

        # Run existence check if provided
        if move_type.existence_check is not None:
            if not move_type.existence_check(self, entity_id, current_container, to_container, params):
                return False, f"Existence check for '{move_name}' returned False"

        return True, None

    def move(
        self,
        move_name: str,
        entity_id: int,
        to_container: int,
        cause: str = 'external',
        source_ops: Optional[List[int]] = None,
        **params
    ) -> Optional[int]:
        """
        Execute a move operation.

        If the operation doesn't exist, returns None.
        If it exists, executes atomically and returns the operation ID.
        """
        exists, reason = self.operation_exists(move_name, entity_id, to_container, **params)

        if not exists:
            # Operation doesn't exist. This isn't an error — it's like calling
            # a method that isn't defined on an object.
            return None

        # Determine the move's dimension
        move_type = self.move_types[move_name]
        move_dim = self._get_move_dimension(move_type)

        # Get current location in the correct dimension
        from_container = self._get_entity_position_in_dimension(entity_id, move_dim)

        # Execute atomically
        self.containers[from_container]._entities.remove(entity_id)
        self.containers[to_container]._entities.add(entity_id)

        # Update the correct location tracking
        if move_dim is None:
            self.entity_location[entity_id] = to_container
        else:
            self.entity_dim_locations[entity_id][move_dim] = to_container

        # Log the operation
        op = Operation(
            id=self.next_op_id,
            op_type=move_name,
            params={
                'entity_id': entity_id,
                'from_container': from_container,
                'to_container': to_container,
                **params
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=cause,
            source_ops=source_ops or []
        )

        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    # =========================================================================
    # QUERIES
    # =========================================================================

    def where_is(self, entity_id: int) -> Optional[int]:
        """Get the container an entity is in."""
        return self.entity_location.get(entity_id)

    def where_is_named(self, entity_id: int) -> Optional[str]:
        """Get the container name an entity is in."""
        container_id = self.entity_location.get(entity_id)
        if container_id is None:
            return None
        return self.containers[container_id].name

    def contents_of(self, container_id: int) -> Set[int]:
        """Get all entities in a container."""
        container = self.containers.get(container_id)
        if container is None:
            return set()
        return container._entities.copy()

    def get_entity_by_name(self, name: str) -> Optional[int]:
        """Get entity ID by name."""
        return self.entity_by_name.get(name)

    def get_container_by_name(self, name: str) -> Optional[int]:
        """Get container ID by name."""
        return self.container_by_name.get(name)

    # =========================================================================
    # DIMENSIONS (Multi-Dimensional State)
    # =========================================================================

    def enroll_in_dimension(
        self,
        entity_id: int,
        container_id: int,
        cause: str = 'external',
        source_ops: Optional[List[int]] = None
    ) -> Optional[int]:
        """
        Place an entity in a dimensional container.

        An entity can occupy one container per dimension. This is for
        INITIAL placement in a dimension — to change position within
        a dimension, use move().

        Returns operation ID, or None if the operation doesn't exist.
        """
        entity = self.entities.get(entity_id)
        if entity is None:
            return None

        container = self.containers.get(container_id)
        if container is None:
            return None

        dim = container.dimension
        if dim is None:
            return None  # Default dimension — use create_entity's initial_container

        # Check: entity not already in a container of this dimension
        dim_locs = self.entity_dim_locations.get(entity_id, {})
        if dim in dim_locs:
            return None  # Already enrolled — use move() to change position

        # Check entity type
        if container.entity_type is not None:
            if entity.type_id != container.entity_type:
                return None

        # Check slot constraint
        if container.kind == ContainerKind.SLOT and not container.is_empty():
            return None

        # Place entity
        container._entities.add(entity_id)
        if entity_id not in self.entity_dim_locations:
            self.entity_dim_locations[entity_id] = {}
        self.entity_dim_locations[entity_id][dim] = container_id

        # Log the operation
        op = Operation(
            id=self.next_op_id,
            op_type='enroll_dimension',
            params={
                'entity_id': entity_id,
                'container': container_id,
                'dimension': dim,
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=cause,
            source_ops=source_ops or []
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    def where_is_in(self, entity_id: int, dimension: str) -> Optional[int]:
        """Get the container an entity is in within a specific dimension."""
        dim_locs = self.entity_dim_locations.get(entity_id, {})
        return dim_locs.get(dimension)

    def where_is_in_named(self, entity_id: int, dimension: str) -> Optional[str]:
        """Get the container name an entity is in within a specific dimension."""
        cid = self.where_is_in(entity_id, dimension)
        if cid is None:
            return None
        return self.containers[cid].name

    def is_entity_in_container(self, entity_id: int, container_id: int) -> bool:
        """
        Check if an entity is in a specific container, in any dimension.

        Works for both default-dimension and named-dimension containers.
        """
        container = self.containers.get(container_id)
        if container is None:
            return False
        return entity_id in container._entities

    # =========================================================================
    # ENTITY PROPERTIES
    # =========================================================================

    def get_property(self, entity_id: int, prop: str) -> Any:
        """Get a property value from an entity."""
        entity = self.entities.get(entity_id)
        if entity is None:
            return None
        return entity.properties.get(prop)

    def set_property(self, entity_id: int, prop: str, value: Any):
        """Set a property value on an entity."""
        entity = self.entities.get(entity_id)
        if entity is not None:
            entity.properties[prop] = value

    # =========================================================================
    # CONSERVATION POOLS AND TRANSFERS
    # =========================================================================

    def define_pool(self, name: str, property_name: str):
        """
        Define a conservation pool.

        A pool ties a property name to conservation semantics.
        The only way to change pool properties after initialization
        is through quantity_transfer, which preserves the total.
        """
        self.pool_defs[name] = {"property": property_name}

    def define_transfer(
        self,
        name: str,
        pool_name: str,
        entity_type: Optional[int] = None
    ):
        """
        Define a quantity transfer type.

        Like define_move for containment, this declares which
        quantity transfers are valid operations.
        """
        self.transfer_types[name] = {
            "pool": pool_name,
            "entity_type": entity_type
        }

    def transfer(
        self,
        transfer_name: str,
        from_entity: int,
        to_entity: int,
        amount: Any,
        cause: str = 'external',
        source_ops: Optional[List[int]] = None
    ) -> Optional[int]:
        """
        Execute a quantity transfer.

        If the operation doesn't exist (wrong type, insufficient amount),
        returns None. Conservation is structural: the total never changes.
        """
        transfer_type = self.transfer_types.get(transfer_name)
        if transfer_type is None:
            return None

        pool = self.pool_defs.get(transfer_type["pool"])
        if pool is None:
            return None

        prop = pool["property"]

        # Type checks
        et = transfer_type.get("entity_type")
        if et is not None:
            from_ent = self.entities.get(from_entity)
            to_ent = self.entities.get(to_entity)
            if from_ent is None or to_ent is None:
                return None
            if from_ent.type_id != et or to_ent.type_id != et:
                return None

        # Self-transfer is meaningless — operation doesn't exist
        if from_entity == to_entity:
            return None

        # Amount must be positive
        if not isinstance(amount, (int, float)) or amount <= 0:
            return None

        from_val = self.get_property(from_entity, prop)
        if from_val is None:
            from_val = 0

        # Operation doesn't exist if source can't cover amount
        if from_val < amount:
            return None

        to_val = self.get_property(to_entity, prop)
        if to_val is None:
            to_val = 0

        # Atomic transfer — conservation guaranteed
        self.set_property(from_entity, prop, from_val - amount)
        self.set_property(to_entity, prop, to_val + amount)

        # Log the operation
        op = Operation(
            id=self.next_op_id,
            op_type=transfer_name,
            params={
                'from_entity': from_entity,
                'to_entity': to_entity,
                'amount': amount,
                'pool': transfer_type['pool'],
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=cause,
            source_ops=source_ops or []
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    # =========================================================================
    # TIME
    # =========================================================================

    def tick(self):
        """Advance to the next tick."""
        self.current_tick += 1
        self.current_micro = 0

    # =========================================================================
    # PROVENANCE
    # =========================================================================

    def why(self, entity_id: int) -> List[Operation]:
        """
        Get all operations that affected an entity.
        """
        result = []
        for op in self.operations:
            if op.params.get('entity_id') == entity_id:
                result.append(op)
        return result

    # =========================================================================
    # TENSIONS (Energy Gradients)
    # =========================================================================

    def define_tension(
        self,
        name: str,
        check: Callable[['MoveGraph'], List[IntendedMove]],
        priority: int = 0
    ):
        """
        Define a tension — a reactive declaration that drives the system.
        
        check: function(graph) -> List[IntendedMove]
            Returns intended moves when the tension is active.
            Returns [] when the tension is satisfied (equilibrium).
        
        priority: Higher priority tensions resolve first.
        """
        self.tensions[name] = Tension(name=name, check=check, priority=priority)

    def step(self) -> List[int]:
        """
        One cycle of tension resolution.

        Checks all tensions in priority order. For each active tension,
        attempts its intended actions (moves, transfers, creates).
        Returns list of operation IDs for actions that executed.

        Returns empty list if system is at equilibrium.
        """
        executed = []

        # Sort tensions by priority (highest first)
        sorted_tensions = sorted(
            self.tensions.values(),
            key=lambda t: t.priority,
            reverse=True
        )

        for tension in sorted_tensions:
            try:
                intended_actions = tension.check(self)
            except Exception:
                continue  # Skip broken tensions gracefully

            for action in intended_actions:
                op_id = None

                if isinstance(action, IntendedMove):
                    op_id = self.move(
                        action.move_name,
                        action.entity_id,
                        action.to_container,
                        cause=f'tension:{tension.name}'
                    )
                elif isinstance(action, IntendedTransfer):
                    op_id = self.transfer(
                        action.transfer_name,
                        action.from_entity,
                        action.to_entity,
                        action.amount,
                        cause=f'tension:{tension.name}'
                    )
                elif isinstance(action, IntendedCreate):
                    op_id = self._create_from_tension(action, tension.name)
                elif isinstance(action, IntendedSet):
                    op_id = self._set_from_tension(action, tension.name)
                elif isinstance(action, IntendedSend):
                    op_id = self.channel_send(
                        action.channel_name,
                        action.entity_id,
                        cause=f'tension:{tension.name}'
                    )
                elif isinstance(action, IntendedReceive):
                    op_id = self.channel_receive(
                        action.channel_name,
                        action.entity_id,
                        action.to_container,
                        cause=f'tension:{tension.name}'
                    )
                elif isinstance(action, IntendedDuplicate):
                    op_id = self.duplicate_entity(
                        action.source_entity,
                        action.container,
                        action.name,
                        cause=f'tension:{tension.name}'
                    )

                if op_id is not None:
                    executed.append(op_id)

        return executed

    def _create_from_tension(
        self,
        create: 'IntendedCreate',
        tension_name: str
    ) -> Optional[int]:
        """
        Create an entity from a tension's emit.

        Returns an operation ID for provenance tracking.
        """
        # Auto-generate unique name
        self._auto_name_counter += 1
        name = create.name or f"_auto_{self._auto_name_counter}"

        entity_id = self.create_entity(
            create.entity_type,
            name,
            create.container,
            create.properties
        )

        # Log as operation for provenance
        op = Operation(
            id=self.next_op_id,
            op_type='create',
            params={
                'entity_id': entity_id,
                'type_id': create.entity_type,
                'container': create.container,
                'properties': dict(create.properties),
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=f'tension:{tension_name}',
            source_ops=[]
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    def _set_from_tension(
        self,
        action: 'IntendedSet',
        tension_name: str
    ) -> Optional[int]:
        """
        Execute a property mutation from a tension.

        Returns None if the entity doesn't exist or the property
        is conserved (part of a pool). Conserved properties can
        only change via transfer — this preserves structural guarantees.
        """
        entity = self.entities.get(action.entity_id)
        if entity is None:
            return None

        # Guard: conserved properties can only change via transfer
        for pool_def in self.pool_defs.values():
            if pool_def["property"] == action.property_name:
                return None  # Conserved — use transfer instead

        # Execute the mutation
        old_value = entity.properties.get(action.property_name)
        entity.properties[action.property_name] = action.value

        # Log for provenance
        op = Operation(
            id=self.next_op_id,
            op_type='set_property',
            params={
                'entity_id': action.entity_id,
                'property': action.property_name,
                'old_value': old_value,
                'new_value': action.value,
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause=f'tension:{tension_name}',
            source_ops=[]
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    def run(self, max_steps: int = 100) -> int:
        """
        Resolve tensions to fixpoint (equilibrium).
        
        Repeatedly calls step() until no moves execute (equilibrium)
        or max_steps is reached (safety valve).
        
        Returns total number of operations executed.
        """
        total_ops = 0
        
        for _ in range(max_steps):
            executed = self.step()
            if not executed:
                break  # Equilibrium reached
            total_ops += len(executed)
        
        return total_ops

    def tick_and_run(self, max_steps: int = 100) -> int:
        """
        Advance time, then resolve tensions to equilibrium.
        
        This is the main execution loop entry point:
        1. Advance tick
        2. Resolve all tensions to fixpoint
        3. Return number of operations executed
        """
        self.tick()
        return self.run(max_steps)

    def signal(self, entity_id: int, container_id: int) -> Optional[int]:
        """
        External signal: place an entity in a container directly.

        Signals are how the outside world disturbs equilibrium.
        After a signal, call run() to let the system respond.

        This bypasses the operation set — signals are external events,
        not system operations. They represent interrupts, I/O completion,
        user input, etc.

        Handles both default-dimension and named-dimension containers.
        """
        entity = self.entities.get(entity_id)
        if entity is None:
            return None

        container = self.containers.get(container_id)
        if container is None:
            return None

        dim = self.container_dimension.get(container_id)

        if dim is None:
            # Default dimension
            current = self.entity_location.get(entity_id)
            if current is not None:
                self.containers[current]._entities.discard(entity_id)
            container._entities.add(entity_id)
            self.entity_location[entity_id] = container_id
        else:
            # Named dimension
            dim_locs = self.entity_dim_locations.get(entity_id, {})
            current = dim_locs.get(dim)
            if current is not None:
                self.containers[current]._entities.discard(entity_id)
            container._entities.add(entity_id)
            if entity_id not in self.entity_dim_locations:
                self.entity_dim_locations[entity_id] = {}
            self.entity_dim_locations[entity_id][dim] = container_id

        # Log as signal operation
        op = Operation(
            id=self.next_op_id,
            op_type='signal',
            params={
                'entity_id': entity_id,
                'from_container': current,
                'to_container': container_id,
                'dimension': dim,
            },
            timestamp=self.current_tick,
            micro=self.current_micro,
            cause='external_signal',
            source_ops=[]
        )
        self.next_op_id += 1
        self.current_micro += 1
        self.operations.append(op)

        return op.id

    # =========================================================================
    # DEBUG
    # =========================================================================

    def dump(self):
        """Print the current state."""
        print(f"=== MoveGraph (tick {self.current_tick}) ===")

        print("\n--- Entity Types ---")
        for type_id, name in self.entity_types.items():
            print(f"  {type_id}: {name}")

        print("\n--- Containers ---")
        for container in self.containers.values():
            contents = [self.entities[e].name or f"#{e}" for e in container._entities]
            print(f"  {container.name} [{container.kind.name}]: {contents}")

        print("\n--- Move Types (Operation Set) ---")
        for name, mt in self.move_types.items():
            from_names = [self.containers[c].name for c in mt.from_containers]
            to_names = [self.containers[c].name for c in mt.to_containers]
            print(f"  {name}: {from_names} -> {to_names}")

        print(f"\n--- Tensions: {len(self.tensions)} ---")
        for name, tension in self.tensions.items():
            print(f"  {name} (priority={tension.priority})")

        print(f"\n--- Operations: {len(self.operations)} ---")


# =============================================================================
# GOAL PURSUIT
# =============================================================================

@dataclass
class PlannedMove:
    """
    A move in a plan.
    """
    move_name: str
    entity_id: int
    to_container: int
    reason: str  # Why this move is needed

    def __repr__(self):
        return f"PlannedMove({self.move_name}, entity={self.entity_id}, to={self.to_container}, reason={self.reason})"


class GoalPursuit:
    """
    Given a MoveGraph and a goal state, find a sequence of moves to reach it.

    This is where the system becomes a planner, not just a state machine.

    THE KEY INSIGHT: We're not searching an abstract state space. We're finding
    sequences of operations that EXIST. If no path exists, it means no sequence
    of valid operations can reach the goal — the goal state is unreachable.
    """

    def __init__(self, graph: MoveGraph):
        self.graph = graph
        self._transition_cache: Dict[int, Dict[int, List[PyTuple[str, int]]]] = {}

    def _build_transition_graph(self, entity_type: int) -> Dict[int, List[PyTuple[str, int]]]:
        """
        Build a graph of valid transitions for an entity type.

        Returns: from_container -> [(move_name, to_container), ...]
        """
        if entity_type in self._transition_cache:
            return self._transition_cache[entity_type]

        transitions: Dict[int, List[PyTuple[str, int]]] = {}

        for name, move_type in self.graph.move_types.items():
            # Check if this move type applies to this entity type
            if move_type.entity_type is not None and move_type.entity_type != entity_type:
                continue

            for from_c in move_type.from_containers:
                if from_c not in transitions:
                    transitions[from_c] = []
                for to_c in move_type.to_containers:
                    transitions[from_c].append((name, to_c))

        self._transition_cache[entity_type] = transitions
        return transitions

    def find_path(
        self,
        entity_id: int,
        goal_container: int
    ) -> Optional[List[PyTuple[str, int]]]:
        """
        Find a sequence of moves to get entity from current position to goal.

        This is the SIMPLE case: assumes no blocking (all target slots are free).

        Returns: list of (move_name, to_container) tuples, or None if no path.
        """
        current = self.graph.where_is(entity_id)
        if current is None:
            return None  # Entity not placed

        if current == goal_container:
            return []  # Already there

        entity = self.graph.entities.get(entity_id)
        if entity is None:
            return None

        transitions = self._build_transition_graph(entity.type_id)

        # BFS from current to goal
        from collections import deque
        queue: deque = deque([(current, [])])
        visited: Set[int] = {current}

        while queue:
            container, path = queue.popleft()

            for move_name, to_container in transitions.get(container, []):
                if to_container in visited:
                    continue

                new_path = path + [(move_name, to_container)]

                if to_container == goal_container:
                    return new_path

                visited.add(to_container)
                queue.append((to_container, new_path))

        return None  # No path exists

    def plan_to_goal(
        self,
        entity_id: int,
        goal_container: int,
        max_depth: int = 10
    ) -> Optional[List[PlannedMove]]:
        """
        Find a complete plan to achieve the goal, handling slot occupancy.

        If the goal container is a SLOT and occupied, this will find moves
        to clear the slot first.

        Returns: List of PlannedMove objects in execution order, or None if impossible.
        """
        return self._plan_recursive(
            entity_id,
            goal_container,
            set(),
            max_depth,
            f"get entity to goal"
        )

    def _plan_recursive(
        self,
        entity_id: int,
        goal_container: int,
        in_progress: Set[int],
        max_depth: int,
        reason: str
    ) -> Optional[List[PlannedMove]]:
        """
        Recursive planning with cycle detection.

        in_progress: set of entity_ids we're currently planning for (prevents cycles)
        """
        if max_depth <= 0:
            return None  # Depth limit reached

        if entity_id in in_progress:
            return None  # Cycle detected — can't plan for entity while already planning for it

        current = self.graph.where_is(entity_id)
        if current is None:
            return None

        if current == goal_container:
            return []  # Already there

        # Check if goal is a slot and occupied
        goal = self.graph.containers.get(goal_container)
        if goal is None:
            return None

        clearing_moves: List[PlannedMove] = []

        if goal.kind == ContainerKind.SLOT and not goal.is_empty():
            # Slot is occupied — need to move the occupant first
            occupants = list(goal._entities)
            if len(occupants) != 1:
                return None  # Slot invariant violated

            occupant_id = occupants[0]

            # Find somewhere for the occupant to go
            occupant = self.graph.entities.get(occupant_id)
            if occupant is None:
                return None

            # Get valid moves for the occupant FROM this slot
            transitions = self._build_transition_graph(occupant.type_id)
            valid_destinations = transitions.get(goal_container, [])

            if not valid_destinations:
                return None  # Occupant can't move — goal unreachable

            # Try each destination for the occupant
            for move_name, dest_container in valid_destinations:
                # Recursively plan for the occupant to reach dest_container
                in_progress_copy = in_progress | {entity_id}
                sub_plan = self._plan_recursive(
                    occupant_id,
                    dest_container,
                    in_progress_copy,
                    max_depth - 1,
                    f"vacate {goal.name} for entity {entity_id}"
                )

                if sub_plan is not None:
                    # sub_plan IS the complete plan to move the occupant
                    # (it finds the path from occupant's current location to dest_container)
                    clearing_moves = sub_plan
                    break
            else:
                return None  # Couldn't find a way to clear the slot

        # Now find path for the target entity
        path = self.find_path(entity_id, goal_container)
        if path is None:
            return None

        # Convert path to PlannedMoves
        entity_moves = [
            PlannedMove(
                move_name=move_name,
                entity_id=entity_id,
                to_container=to_container,
                reason=reason
            )
            for move_name, to_container in path
        ]

        return clearing_moves + entity_moves

    def execute_plan(self, plan: List[PlannedMove]) -> List[Optional[int]]:
        """
        Execute a plan, returning operation IDs for each successful move.

        If a move fails (operation doesn't exist), subsequent moves may also fail.
        """
        results = []
        for move in plan:
            op_id = self.graph.move(
                move.move_name,
                move.entity_id,
                move.to_container,
                cause='planned'
            )
            results.append(op_id)
        return results


# =============================================================================
# DEMONSTRATION: PROCESS SCHEDULING
# =============================================================================

def demo_process_scheduling():
    """
    Demonstrate process scheduling using MOVE.

    Process state is "which queue the process is in."
    Valid transitions are declared in the schema.
    Invalid transitions don't exist — not "rejected", just don't exist.
    """
    print("=" * 60)
    print("DEMO: Process Scheduling with MOVE Primitive")
    print("=" * 60)

    g = MoveGraph()

    # Define entity type
    process_type = g.define_entity_type("Process")

    # Define containers (process states)
    ready_queue = g.define_container("READY_QUEUE", entity_type=process_type)
    running_cpu0 = g.define_container("RUNNING_CPU0", ContainerKind.SLOT, entity_type=process_type)
    running_cpu1 = g.define_container("RUNNING_CPU1", ContainerKind.SLOT, entity_type=process_type)
    blocked_queue = g.define_container("BLOCKED_QUEUE", entity_type=process_type)
    zombie_list = g.define_container("ZOMBIE_LIST", entity_type=process_type)

    # Define the operation set (valid moves)
    g.define_move("schedule",
        from_containers=[ready_queue],
        to_containers=[running_cpu0, running_cpu1],
        entity_type=process_type)

    g.define_move("preempt",
        from_containers=[running_cpu0, running_cpu1],
        to_containers=[ready_queue],
        entity_type=process_type)

    g.define_move("block",
        from_containers=[running_cpu0, running_cpu1],
        to_containers=[blocked_queue],
        entity_type=process_type)

    g.define_move("unblock",
        from_containers=[blocked_queue],
        to_containers=[ready_queue],
        entity_type=process_type)

    g.define_move("exit",
        from_containers=[running_cpu0, running_cpu1],
        to_containers=[zombie_list],
        entity_type=process_type)

    # Create processes
    init_process = g.create_entity(process_type, "init", ready_queue)
    shell_process = g.create_entity(process_type, "shell", ready_queue)
    daemon_process = g.create_entity(process_type, "daemon", ready_queue)

    print("\n--- Initial State ---")
    g.dump()

    # Schedule init to CPU0
    print("\n--- Scheduling init to CPU0 ---")
    result = g.move("schedule", init_process, running_cpu0)
    print(f"  Operation {'succeeded' if result else 'does not exist'} (op_id={result})")
    print(f"  init is now in: {g.where_is_named(init_process)}")

    # Schedule shell to CPU1
    print("\n--- Scheduling shell to CPU1 ---")
    result = g.move("schedule", shell_process, running_cpu1)
    print(f"  Operation {'succeeded' if result else 'does not exist'} (op_id={result})")
    print(f"  shell is now in: {g.where_is_named(shell_process)}")

    # Try to schedule daemon to CPU0 (should fail — slot occupied)
    print("\n--- Trying to schedule daemon to CPU0 (slot occupied) ---")
    exists, reason = g.operation_exists("schedule", daemon_process, running_cpu0)
    print(f"  Operation exists: {exists}")
    print(f"  Reason: {reason}")
    result = g.move("schedule", daemon_process, running_cpu0)
    print(f"  Move result: {result}")
    print(f"  daemon is still in: {g.where_is_named(daemon_process)}")

    # Block shell (I/O wait)
    print("\n--- Blocking shell (I/O wait) ---")
    result = g.move("block", shell_process, blocked_queue)
    print(f"  Operation {'succeeded' if result else 'does not exist'} (op_id={result})")
    print(f"  shell is now in: {g.where_is_named(shell_process)}")

    # Now daemon can be scheduled to CPU1
    print("\n--- Now scheduling daemon to CPU1 (freed up) ---")
    result = g.move("schedule", daemon_process, running_cpu1)
    print(f"  Operation {'succeeded' if result else 'does not exist'} (op_id={result})")
    print(f"  daemon is now in: {g.where_is_named(daemon_process)}")

    # Try invalid transition: BLOCKED -> RUNNING (doesn't exist)
    print("\n--- Trying invalid: shell from BLOCKED to RUNNING_CPU0 ---")
    exists, reason = g.operation_exists("schedule", shell_process, running_cpu0)
    print(f"  Operation exists: {exists}")
    print(f"  Reason: {reason}")

    # Correct path: BLOCKED -> READY -> RUNNING
    print("\n--- Correct path: unblock shell, then schedule ---")
    result = g.move("unblock", shell_process, ready_queue)
    print(f"  Unblock result: {result} (shell -> READY)")
    result = g.move("schedule", shell_process, running_cpu0)
    print(f"  Schedule result: {result} (shell -> CPU0, preempts init)")

    # Wait, init is still on CPU0. Need to preempt first.
    print("\n  Oops, CPU0 is still occupied by init. Let's preempt init first:")
    result = g.move("preempt", init_process, ready_queue)
    print(f"  Preempt init: {result}")
    result = g.move("schedule", shell_process, running_cpu0)
    print(f"  Schedule shell to CPU0: {result}")

    print("\n--- Final State ---")
    g.dump()

    print("\n--- Provenance: What happened to shell? ---")
    for op in g.why(shell_process):
        print(f"  {op.op_type}: {op.params.get('from_container')} -> {op.params.get('to_container')}")

    print("\n" + "=" * 60)
    print("KEY INSIGHT: We never 'checked' if transitions were valid.")
    print("We only asked 'does this operation exist?' and if so, executed it.")
    print("Invalid states (process in two places, blocked->running) are")
    print("unreachable because the operations to reach them don't exist.")
    print("=" * 60)


# =============================================================================
# TEST: Prove Double-Spend Is Impossible
# =============================================================================

def test_double_spend_impossible():
    """
    The double-spend bug from Session 23 can't happen with MOVE.

    Two players can't both buy the same item because:
    - Item is in shop_inventory (a container)
    - MOVE "purchase" only allows from=shop_inventory
    - MOVE(item, from=shop_inventory, to=alice_inventory) succeeds
    - MOVE(item, from=shop_inventory, to=bob_inventory) doesn't exist
      because item is no longer in shop_inventory

    The key insight: we define SEPARATE move types for purchase vs. trade.
    A "purchase" can only take from shop. A "trade" can move between players.
    """
    print("\n" + "=" * 60)
    print("TEST: Double-Spend is Structurally Impossible")
    print("=" * 60)

    g = MoveGraph()

    # Entity types
    item_type = g.define_entity_type("Item")

    # Containers (inventories)
    shop_inventory = g.define_container("shop_inventory", entity_type=item_type)
    alice_inventory = g.define_container("alice_inventory", entity_type=item_type)
    bob_inventory = g.define_container("bob_inventory", entity_type=item_type)

    # The PURCHASE operation: can only take FROM shop, TO player inventories
    g.define_move("purchase",
        from_containers=[shop_inventory],
        to_containers=[alice_inventory, bob_inventory],
        entity_type=item_type)

    # (Could also define "trade" for player-to-player, "sell" for player-to-shop)

    # Create sword in shop
    sword = g.create_entity(item_type, "legendary_sword", shop_inventory)

    print(f"\n  Initial: sword is in {g.where_is_named(sword)}")

    # Alice's purchase
    print("\n  Alice's purchase:")
    exists_alice, reason = g.operation_exists("purchase", sword, alice_inventory)
    print(f"    Operation exists: {exists_alice}")
    result = g.move("purchase", sword, alice_inventory)
    print(f"    Result: {result}")
    print(f"    Sword is now in: {g.where_is_named(sword)}")

    # Bob's purchase (should not exist - sword no longer in shop)
    print("\n  Bob's purchase:")
    exists_bob, reason = g.operation_exists("purchase", sword, bob_inventory)
    print(f"    Operation exists: {exists_bob}")
    print(f"    Reason: {reason}")
    result = g.move("purchase", sword, bob_inventory)
    print(f"    Result: {result}")
    print(f"    Sword is still in: {g.where_is_named(sword)}")

    # Verify
    in_alice = sword in g.contents_of(alice_inventory)
    in_bob = sword in g.contents_of(bob_inventory)
    in_shop = sword in g.contents_of(shop_inventory)

    print(f"\n  Final state:")
    print(f"    In alice_inventory: {in_alice}")
    print(f"    In bob_inventory: {in_bob}")
    print(f"    In shop_inventory: {in_shop}")

    # The sword is in exactly one place
    locations = [in_alice, in_bob, in_shop]
    assert sum(locations) == 1, "Sword should be in exactly one place!"
    assert in_alice, "Alice should have the sword!"

    print("\n  [OK] Double-spend is IMPOSSIBLE.")
    print("       Bob's operation didn't 'fail' - it DOESN'T EXIST.")
    print("       A 'purchase' requires from=shop_inventory.")
    print("       The sword is no longer there, so the operation isn't there.")


# =============================================================================
# TEST: Memory Region State Machine
# =============================================================================

def test_memory_region_states():
    """
    Memory regions transition through states:
    UNMAPPED -> MAPPED_PRIVATE -> COPY_ON_WRITE -> MAPPED_PRIVATE (after fork+write)

    This demonstrates that the MOVE primitive handles state machines naturally.
    """
    print("\n" + "=" * 60)
    print("TEST: Memory Region State Machine")
    print("=" * 60)

    g = MoveGraph()

    # Entity type
    region_type = g.define_entity_type("MemoryRegion")

    # Containers (states)
    unmapped = g.define_container("UNMAPPED", entity_type=region_type)
    mapped_private = g.define_container("MAPPED_PRIVATE", entity_type=region_type)
    mapped_shared = g.define_container("MAPPED_SHARED", entity_type=region_type)
    cow = g.define_container("COPY_ON_WRITE", entity_type=region_type)

    # Valid state transitions (the operation set)
    g.define_move("mmap_private",
        from_containers=[unmapped],
        to_containers=[mapped_private],
        entity_type=region_type)

    g.define_move("mmap_shared",
        from_containers=[unmapped],
        to_containers=[mapped_shared],
        entity_type=region_type)

    g.define_move("fork_copy",
        from_containers=[mapped_private, mapped_shared],
        to_containers=[cow],
        entity_type=region_type)

    g.define_move("cow_trigger",
        from_containers=[cow],
        to_containers=[mapped_private],
        entity_type=region_type)

    g.define_move("munmap",
        from_containers=[mapped_private, mapped_shared, cow],
        to_containers=[unmapped],
        entity_type=region_type)

    # Create a memory region
    region = g.create_entity(region_type, "region_0x1000", unmapped)

    print(f"\n  Initial: region is {g.where_is_named(region)}")

    # Map it private
    print("\n  mmap_private:")
    result = g.move("mmap_private", region, mapped_private)
    print(f"    Result: {result}")
    print(f"    Region is now: {g.where_is_named(region)}")

    # Try invalid: can't mmap_shared a region that's already mapped
    print("\n  Try mmap_shared (already mapped):")
    exists, reason = g.operation_exists("mmap_shared", region, mapped_shared)
    print(f"    Operation exists: {exists}")
    print(f"    Reason: {reason}")

    # Fork creates COW copy
    print("\n  fork_copy (simulate fork):")
    result = g.move("fork_copy", region, cow)
    print(f"    Result: {result}")
    print(f"    Region is now: {g.where_is_named(region)}")

    # Write triggers COW
    print("\n  cow_trigger (first write after fork):")
    result = g.move("cow_trigger", region, mapped_private)
    print(f"    Result: {result}")
    print(f"    Region is now: {g.where_is_named(region)}")

    # Try invalid: can't fork_copy from MAPPED_PRIVATE directly to MAPPED_PRIVATE
    print("\n  Try fork_copy -> MAPPED_PRIVATE (invalid transition):")
    exists, reason = g.operation_exists("fork_copy", region, mapped_private)
    print(f"    Operation exists: {exists}")
    print(f"    Reason: {reason}")

    # Unmap
    print("\n  munmap:")
    result = g.move("munmap", region, unmapped)
    print(f"    Result: {result}")
    print(f"    Region is now: {g.where_is_named(region)}")

    print("\n  [OK] Memory region state machine works correctly.")
    print("       Only valid state transitions exist as operations.")


# =============================================================================
# TEST: File Descriptor Conservation
# =============================================================================

def test_fd_conservation():
    """
    File descriptors are conserved: the total in (free_pool + allocated) is constant.

    This demonstrates conservation with quantity tracking.
    (Simplified version - full implementation would use quantity pools)
    """
    print("\n" + "=" * 60)
    print("TEST: File Descriptor Table (Conservation)")
    print("=" * 60)

    g = MoveGraph()

    # Entity type
    fd_type = g.define_entity_type("FileDescriptor")

    # Containers: free pool and slots 0-4
    free_pool = g.define_container("FREE_POOL", entity_type=fd_type)
    fd_slots = []
    for i in range(5):
        slot = g.define_container(f"FD_SLOT_{i}", ContainerKind.SLOT, entity_type=fd_type)
        fd_slots.append(slot)

    # Operations
    g.define_move("allocate",
        from_containers=[free_pool],
        to_containers=fd_slots,
        entity_type=fd_type)

    g.define_move("deallocate",
        from_containers=fd_slots,
        to_containers=[free_pool],
        entity_type=fd_type)

    g.define_move("dup2",
        from_containers=fd_slots,
        to_containers=fd_slots,
        entity_type=fd_type)

    # Create file descriptors in free pool
    fds = []
    for i in range(5):
        fd = g.create_entity(fd_type, f"fd_{i}", free_pool)
        fds.append(fd)

    def count_state():
        free = len(g.contents_of(free_pool))
        allocated = sum(len(g.contents_of(s)) for s in fd_slots)
        return free, allocated, free + allocated

    print(f"\n  Initial state:")
    free, alloc, total = count_state()
    print(f"    Free: {free}, Allocated: {alloc}, Total: {total}")

    # Allocate fd_0 to slot 0
    print("\n  Allocate fd_0 to slot 0 (simulates open()):")
    result = g.move("allocate", fds[0], fd_slots[0])
    print(f"    Result: {result}")
    free, alloc, total = count_state()
    print(f"    Free: {free}, Allocated: {alloc}, Total: {total}")

    # Allocate fd_1 to slot 1
    print("\n  Allocate fd_1 to slot 1:")
    result = g.move("allocate", fds[1], fd_slots[1])
    free, alloc, total = count_state()
    print(f"    Free: {free}, Allocated: {alloc}, Total: {total}")

    # Try to allocate fd_2 to slot 0 (already occupied)
    print("\n  Try allocate fd_2 to slot 0 (occupied):")
    exists, reason = g.operation_exists("allocate", fds[2], fd_slots[0])
    print(f"    Operation exists: {exists}")
    print(f"    Reason: {reason}")

    # Deallocate fd_0 from slot 0
    print("\n  Deallocate fd_0 (simulates close()):")
    result = g.move("deallocate", fds[0], free_pool)
    free, alloc, total = count_state()
    print(f"    Free: {free}, Allocated: {alloc}, Total: {total}")

    # Now we can allocate fd_2 to slot 0
    print("\n  Now allocate fd_2 to slot 0:")
    result = g.move("allocate", fds[2], fd_slots[0])
    free, alloc, total = count_state()
    print(f"    Free: {free}, Allocated: {alloc}, Total: {total}")

    print(f"\n  Total FDs throughout: always {total} (conserved)")
    print("  [OK] File descriptors conserved: total never changes.")


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    demo_process_scheduling()
    test_double_spend_impossible()
    test_memory_region_states()
    test_fd_conservation()
