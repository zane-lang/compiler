"""Five levels warns; six fails."""


def at_limit(xs):
    for x in xs:
        while x:
            if x:
                with open(x) as f:
                    try:
                        f.read()
                    except OSError:
                        pass


def past_limit(xs):
    for x in xs:
        while x:
            if x:
                with open(x) as f:
                    try:
                        match f:
                            case _:
                                pass
                    except OSError:
                        pass


def elif_chain(x):
    """An `elif` chain is one level, so this is four deep, not seven."""
    if x == 1:
        return 1
    elif x == 2:
        return 2
    elif x == 3:
        return 3
    elif x == 4:
        for y in x:
            while y:
                if y:
                    return 4
    return 0


def named_step(xs):
    """The inner function is measured on its own: each is three deep."""
    for x in xs:
        def step(y):
            while y:
                if y:
                    for _ in y:
                        pass
        if x:
            step(x)
