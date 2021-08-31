
/**
 * https://javadoc.io/doc/org.janusgraph/janusgraph-core/latest/org/janusgraph/core/schema/JanusGraphManagement.html
 */

/**
 *  Make each index
 */

indexList.forEach { ixName, propName, modifier ->
    mgmt = graph.openManagement()
    if (mgmt.containsGraphIndex(ixName)) {
        mgmt.commit()
        return;
    }
    pk = mgmt.getPropertyKey(propName)
    switch (modifier) {
        case 'unique':
            mgmt .buildIndex ( ixName, Vertex.class ).addKey ( pk ).unique().buildCompositeIndex ( )
        default:
            mgmt .buildIndex ( ixName, Vertex.class ).addKey ( pk ).buildCompositeIndex ( )
    }
    mgmt.commit()
}

graph.tx().commit()

/**
 *  Wait for the status of each index to change from INSTALLED to REGISTERED
 */
indexList.forEach { ixName, propName, modifier ->
    report = ManagementSystem.awaitGraphIndexStatus(graph, ixName).status(SchemaStatus.REGISTERED).call()
}

/**
 *  Reindex each existing data
 */
indexList.forEach { ixName, propName, modifier ->
    mgmt = graph.openManagement()
    ix = mgmt.getGraphIndex(ixName)
    mgmt.updateIndex(ix, SchemaAction.REINDEX)
    mgmt.commit()
}

/**
 *  Block until the indexes are ENABLED
 */
indexList.forEach { ixName, propName, modifier ->
    mgmt = graph.openManagement()
    report = ManagementSystem.awaitGraphIndexStatus(graph, ixName).status(SchemaStatus.ENABLED).call()
    mgmt.commit()
}

/**
 * Show the results
 */
mgmt = graph.openManagement()
mgmt.printSchema()
//mgmt.printIndexes()
mgmt.commit()