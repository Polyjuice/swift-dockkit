All updates should go through the reconciler. We are using a reactive model.
The json layout is the single source of truth. Check how panels are added. Read this document: /Users/jack/evryzin/swift-dockkit/ARCHITECTURE.md

Does the adding of stage follow this principle.

I.e
```
addNewStage -> read json layout -> create a new json layout -> send to
    reactive reconsiler
```

I.e. there must be no side loading of panels/stages/windows that does not
go through the reconciler