/// Yields until a condition holds. The budget is a count of yields, not
/// time, and deliberately enormous (`testYieldBudget`): a loaded machine
/// never exhausts it (a 5,000-yield budget did), while a real hang fails with
/// the last observed state instead of stalling the suite.
let testYieldBudget = 10_000_000
