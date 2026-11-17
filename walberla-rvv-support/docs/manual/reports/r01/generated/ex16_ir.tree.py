def show_tree(node, depth=0, out=None):
    out = [] if out is None else out
    dtype = getattr(node, "dtype", None)
    out.append("  " * depth + type(node).__name__ + (f"  : {dtype}" if dtype else ""))
    for child in node.children:
        show_tree(child, depth + 1, out)
    return out
