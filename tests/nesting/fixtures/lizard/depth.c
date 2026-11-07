/* Five levels warns; six fails. */
void at_limit(int x) {
  for (;;) {
    while (x) {
      if (x) {
        do {
          if (x) { x--; }
        } while (x);
      }
    }
  }
}

void past_limit(int x) {
  for (;;) {
    while (x) {
      if (x) {
        do {
          switch (x) {
          case 1:
            if (x) { x--; }
            break;
          }
        } while (x);
      }
    }
  }
}

/* Each `else if` is a level of its own to lizard: this chain is five deep. */
int chain(int x) {
  if (x == 1) return 1;
  else if (x == 2) return 2;
  else if (x == 3) return 3;
  else if (x == 4) return 4;
  else if (x == 5) return 5;
  return 0;
}

/* The same choice as a switch is one level. */
int switched(int x) {
  switch (x) {
  case 1: return 1;
  case 2: return 2;
  case 3: return 3;
  case 4: return 4;
  case 5: return 5;
  }
  return 0;
}
