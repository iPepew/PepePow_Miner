"""CPU queue ownership model; not CUDA correctness or performance evidence."""
import random
import struct


def check(block, active_count, probability, rng):
    tasks = {i for i in range(active_count) if rng.random() < probability}
    warps = list(range(block // 32))
    rng.shuffle(warps)  # legal arbitrary order of warp atomicAdd reservations
    slots = {}
    queue = []
    for warp in warps:
        members = [i for i in range(warp * 32, warp * 32 + 32) if i in tasks]
        base = len(queue)
        for rank, owner in enumerate(members):
            slots[owner] = base + rank
        queue.extend(members)
    assert len(queue) <= block and len(set(slots.values())) == len(tasks)
    # Arbitrary result bit patterns test routing without assuming any FP math.
    expected = {owner: rng.getrandbits(64) for owner in tasks}
    old_results = {}
    new_results = [None] * block
    lanes = list(range(32))
    rng.shuffle(lanes)
    for lane in lanes:
        for task_index in range(lane, len(queue), 32):
            owner = queue[task_index]
            old_results[owner] = expected[owner]
            new_results[task_index] = expected[owner]
    for owner in tasks:
        assert new_results[slots[owner]] == old_results[owner]
    # Inactive and zero-nibble producers must never read a stale slot.
    assert set(slots) == tasks


if __name__ == '__main__':
    rng = random.Random(20261021)
    cases = 0
    for block in range(64, 769, 32):
        for active_count in (0, 1, 31, 32, 33, block - 1, block):
            for probability in (0.0, 0.01, 0.1, 0.5, 0.9375, 1.0):
                for _ in range(16):
                    check(block, active_count, probability, rng)
                    cases += 1
    print(f'PASS {cases} queue-routing cases; CUDA compile/GPU correctness/performance NOT tested')
