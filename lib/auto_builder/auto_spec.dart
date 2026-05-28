class BattlecryPassSpec {
  String start;
  bool risky;
  bool greedy;
  bool hub;
  String route;
  bool localize;

  BattlecryPassSpec({
    this.start = 'rush',
    this.risky = false,
    this.greedy = false,
    this.hub = true,
    this.route = 'Far -> Close',
    this.localize = true,
  });

  BattlecryPassSpec copy() {
    return BattlecryPassSpec(
      start: start,
      risky: risky,
      greedy: greedy,
      hub: hub,
      route: route,
      localize: localize,
    );
  }
}

class BattlecryFinalSpec {
  String type;
  String dot;
  bool risky;
  bool greedy;
  bool hub;
  String route;

  BattlecryFinalSpec({
    this.type = 'dot',
    this.dot = 'center',
    this.risky = false,
    this.greedy = false,
    this.hub = true,
    this.route = 'Far -> Close',
  });

  BattlecryFinalSpec copy() {
    return BattlecryFinalSpec(
      type: type,
      dot: dot,
      risky: risky,
      greedy: greedy,
      hub: hub,
      route: route,
    );
  }
}

class BattlecryAutoSpec {
  List<BattlecryPassSpec> passes;
  BattlecryFinalSpec? finalSpec;

  BattlecryAutoSpec({
    List<BattlecryPassSpec>? passes,
    this.finalSpec,
  }) : passes = passes ?? [];

  BattlecryAutoSpec copy() {
    return BattlecryAutoSpec(
      passes: passes.map((p) => p.copy()).toList(),
      finalSpec: finalSpec?.copy(),
    );
  }
}
